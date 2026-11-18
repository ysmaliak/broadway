import AppKit
import WebKit
import Testing
@testable import Search

struct AuditCase: CustomTestStringConvertible, Sendable {
    let rule: String
    let broken: String
    let kept: String

    var testDescription: String { rule }

    static func page(_ body: String, lang: Bool = true, title: Bool = true, heading: Bool = true) -> String {
        "<!doctype html><html\(lang ? " lang=\"en\"" : "")><head><meta charset=\"utf-8\">\(title ? "<title>Fixture</title>" : "")</head><body>\(heading ? "<h1>Fixture</h1>" : "")\(body)</body></html>"
    }

    static let all: [AuditCase] = [
        AuditCase(rule: "img-alt", broken: page("<img src=\"/none.png\" width=\"40\" height=\"40\">"), kept: page("<img src=\"/none.png\" alt=\"\" width=\"40\" height=\"40\">")),
        AuditCase(rule: "control-name", broken: page("<button style=\"width:40px;height:40px\"></button>"), kept: page("<button style=\"width:80px;height:40px\">Save</button>")),
        AuditCase(rule: "field-label", broken: page("<input placeholder=\"Email\" style=\"height:30px\">"), kept: page("<label for=\"mail\">Email</label> <input id=\"mail\" style=\"height:30px\">")),
        AuditCase(rule: "page-lang", broken: page("<p>Words</p>", lang: false), kept: page("<p>Words</p>")),
        AuditCase(rule: "page-title", broken: page("<p>Words</p>", title: false), kept: page("<p>Words</p>")),
        AuditCase(rule: "heading-skip", broken: page("<h3>Deep</h3>"), kept: page("<h2>Next</h2>")),
        AuditCase(rule: "heading-one", broken: page("<h2>Only second</h2>", heading: false), kept: page("<h2>Second</h2>")),
        AuditCase(rule: "duplicate-id", broken: page("<label for=\"who\">Name</label> <input id=\"who\" style=\"height:30px\"><div id=\"who\">Twin</div>"),
                  kept: page("<label for=\"who\">Name</label> <input id=\"who\" style=\"height:30px\"><div id=\"other\">Other</div>")),
        AuditCase(rule: "contrast", broken: page("<p style=\"color:#b8b8b8;background:#ffffff\">Faint words</p>"), kept: page("<p style=\"color:#222222;background:#ffffff\">Plain words</p>")),
        AuditCase(rule: "target-size", broken: page("<button style=\"width:16px;height:16px;padding:0\">x</button>"), kept: page("<button style=\"width:32px;height:32px;padding:0\">x</button>")),
        AuditCase(rule: "keyboard", broken: page("<div role=\"button\" style=\"width:80px;height:30px\">Open</div>"), kept: page("<div role=\"button\" tabindex=\"0\" style=\"width:80px;height:30px\">Open</div>")),
        AuditCase(rule: "tab-order", broken: page("<p><a href=\"/next\" tabindex=\"3\" style=\"display:inline-block;padding:8px\">Next page</a></p>"), kept: page("<p><a href=\"/next\" style=\"display:inline-block;padding:8px\">Next page</a></p>")),
    ]
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentChecksTests {
    private let task = UUID()
    private var browser: Browser!
    private var box: BrowserToolbox!
    private var server: LocalPageServer?

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
        server?.stop()
        AgentSites.shared.reset()
        AgentDesk.shared.drop(task: task)
        browser?.closeAll()
        browser = nil
    }

    private func open(_ pages: [String: LocalPageServer.Page], at path: String = "/page") async throws -> (tab: Tab, id: String) {
        server?.stop()
        server = try LocalPageServer(pages)
        let before = Set(browser.tabs.map(\.id))
        _ = await box.call("open", ["url": server!.url(path).absoluteString], task: task)
        let tab = try #require(browser.tabs.first { !before.contains($0.id) })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id], task: task)
        return (tab, id)
    }

    private func rules(_ html: String) async throws -> [String] {
        let (_, id) = try await open(["/page": .init(type: "text/html", body: html)])
        let said = await box.call("audit", ["tab": id], task: task)
        #expect(!said.failed, "\(said.text ?? "")")
        let findings = said.data?["findings"] as? [[String: Any]] ?? []
        return findings.compactMap { $0["rule"] as? String }
    }

    @Test(arguments: AuditCase.all)
    func eachRuleFlagsThePageThatBreaksItAndNotThePageThatKeepsIt(_ check: AuditCase) async throws {
        let broken = try await rules(check.broken)
        #expect(broken.contains(check.rule), "\(check.rule) not in \(broken)")
        let kept = try await rules(check.kept)
        #expect(!kept.contains(check.rule), "\(check.rule) in \(kept)")
    }

    @Test func theAuditSaysItIsAFirstPassAndGivesEachFindingARefAndItsWords() async throws {
        let (_, id) = try await open(["/page": .init(type: "text/html", body: AuditCase.page("<button style=\"width:16px;height:16px;padding:0\">Go</button>"))])
        let said = await box.call("audit", ["tab": id], task: task)
        #expect(said.text?.contains(AgentChecks.firstPass) == true)
        let finding = try #require((said.data?["findings"] as? [[String: Any]])?.first { $0["rule"] as? String == "target-size" })
        #expect((finding["ref"] as? String)?.hasPrefix("e") == true)
        #expect(finding["words"] as? String == "Go")
        #expect(said.text?.contains("@\(finding["ref"] as? String ?? "")") == true)
    }

    @Test func theAuditShowsFiftyFindingsAndCountsTheRest() async throws {
        let fields = (0..<80).map { "<input style=\"height:30px\" name=\"f\($0)\">" }.joined()
        let (_, id) = try await open(["/page": .init(type: "text/html", body: AuditCase.page(fields))])
        let said = await box.call("audit", ["tab": id], task: task)
        #expect((said.data?["findings"] as? [[String: Any]])?.count == 50)
        #expect(said.data?["more"] as? Int == 30)
        #expect(said.text?.contains("30 more not shown") == true)
    }

    @Test func contrastOnAGradientIsNotChecked() async throws {
        let body = AuditCase.page("<p style=\"color:#bbbbbb;background:linear-gradient(#ffffff,#fefefe)\">On a gradient</p>")
        let (_, id) = try await open(["/page": .init(type: "text/html", body: body)])
        let said = await box.call("audit", ["tab": id], task: task)
        let found = (said.data?["findings"] as? [[String: Any]] ?? []).compactMap { $0["rule"] as? String }
        #expect(!found.contains("contrast"))
        #expect((said.data?["contrast_unchecked"] as? Int ?? 0) >= 1)
        #expect(said.text?.contains("on a picture or a gradient") == true)
    }

    @Test func theAuditNeverShowsWhatIsInAPasswordBox() async throws {
        let body = AuditCase.page("<input type=\"password\" value=\"plum-otter-4471\" style=\"height:30px\">")
        let (_, id) = try await open(["/page": .init(type: "text/html", body: body)])
        let said = await box.call("audit", ["tab": id], task: task)
        #expect(said.text?.contains("plum-otter-4471") == false)
        #expect("\(said.data ?? [:])".contains("plum-otter-4471") == false)
    }

    @Test func timingsNameASlowResourceAmongTheSlowest() async throws {
        let body = AuditCase.page("<img src=\"/slow.png?token=abc123secret\" alt=\"Slow\" width=\"10\" height=\"10\">")
        let (_, id) = try await open(["/page": .init(type: "text/html", body: body), "/slow.png": .init(type: "image/png", body: "not really a picture", hold: 0.7)])
        let said = await box.call("timings", ["tab": id], task: task)
        #expect(!said.failed, "\(said.text ?? "")")
        let slowest = try #require((said.data?["slowest"] as? [[String: Any]])?.first)
        #expect((slowest["url"] as? String)?.contains("/slow.png") == true)
        #expect((slowest["ms"] as? Int ?? 0) >= 600)
        #expect(said.data?["first_byte_ms"] is Int)
        #expect(said.text?.contains("abc123secret") == false)
    }

    @Test func aNumberThePageDidNotRecordSaysNotAvailable() {
        let said = AgentChecks.timings(["firstByte": 12, "slowest": [["url": "http://127.0.0.1/a.js", "ms": 40, "type": "script"]]])
        #expect(said.data?["ready_ms"] as? String == "not available")
        #expect(said.data?["layout_shift"] as? String == "not available")
        #expect(said.data?["largest_paint"] as? String == "not available")
        #expect(said.data?["long_tasks"] as? String == "not available")
        #expect(said.text?.contains("Document ready: not available") == true)
        #expect(said.text?.contains("size not available") == true)
        #expect(said.text?.contains("Largest paint: 0") == false)
    }

    @Test func stylesNameTheAncestorThatClipsAnElement() async throws {
        let body = AuditCase.page("<div id=\"frame\" style=\"overflow:hidden;width:100px;height:50px\"><button style=\"width:300px;height:30px\">Wide button</button></div>")
        let (_, id) = try await open(["/page": .init(type: "text/html", body: body)])
        let said = await box.call("styles", ["tab": id, "target": "Wide button"], task: task)
        #expect(!said.failed, "\(said.text ?? "")")
        let cut = try #require((said.data?["hiddenBy"] as? [[String: Any]])?.first)
        #expect((cut["element"] as? String)?.hasPrefix("div#frame") == true)
        #expect(((cut["why"] as? [String]) ?? []).contains { $0.contains("overflow hidden cuts it to 100×30") })
        #expect((said.data?["box"] as? [String: Any])?["width"] as? Double == 300)
        #expect(said.text?.contains("Clipped or hidden by:") == true)
    }

    @Test func stylesOnAPasswordBoxNeverGiveItsValue() async throws {
        let body = AuditCase.page("<label for=\"pw\">Password</label><input id=\"pw\" type=\"password\" value=\"plum-otter-4471\">")
        let (_, id) = try await open(["/page": .init(type: "text/html", body: body)])
        let said = await box.call("styles", ["tab": id, "target": "Password"], task: task)
        #expect(!said.failed, "\(said.text ?? "")")
        #expect(said.data?["secret"] as? Bool == true)
        #expect(said.text?.contains("plum-otter-4471") == false)
        #expect("\(said.data ?? [:])".contains("plum-otter-4471") == false)
    }

    @Test func neverHereRefusesTheChecksInTheSameWordsAsConsole() async throws {
        let (tab, id) = try await open(["/page": .init(type: "text/html", body: AuditCase.page("<button>Go</button>"))])
        let site = try #require(AgentSites.site(of: tab.pageAddress))
        AgentSites.shared.set(.never, for: site)
        let console = await box.call("console", ["tab": id], task: task)
        #expect(console.failed)
        for name in ["audit", "timings"] {
            let said = await box.call(name, ["tab": id], task: task)
            #expect(said.failed)
            #expect(said.text == console.text)
            #expect(said.code == console.code)
        }
        let styles = await box.call("styles", ["tab": id, "target": "Go"], task: task)
        #expect(styles.text == console.text)
    }

    @Test func aPageStoppedOverItsMemoryRefusesTheChecksAndRowsWithItsCode() async throws {
        let (tab, id) = try await open(["/page": .init(type: "text/html", body: AuditCase.page("<ul><li>One</li><li>Two</li></ul><button>Go</button>"))])
        let calls: [(String, [String: Any])] = [("audit", [:]), ("timings", [:]), ("styles", ["target": "Go"]), ("text", ["rows": true])]
        for (name, extra) in calls {
            tab.memoryOwed = true
            let said = await box.call(name, extra.merging(["tab": id]) { a, _ in a }, task: task)
            #expect(said.code == "page_too_large", "\(name): \(said.text ?? "")")
            #expect(said.retrySafe == false)
        }
    }

    @Test func theChecksWorkOnlyInATabOfTheAgentsOwn() async throws {
        server = try LocalPageServer(["/page": .init(type: "text/html", body: AuditCase.page("<button>Go</button>"))])
        let mine = Tab(configuration: Web.configuration(space: browser.spaceID))
        browser.showRow([mine], active: mine.id)
        mine.go(to: server!.url("/page"))
        let id = String(mine.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id], task: task)
        let said = await box.call("audit", ["tab": id], task: task)
        #expect(said.failed)
        #expect(said.text?.contains("Only tabs an agent opened") == true)
    }

    @Test func theMCPListMarksTheChecksReadOnly() {
        for name in ["audit", "timings", "styles"] {
            #expect(MCPServer.annotations(name)["readOnlyHint"] as? Bool == true)
            #expect(MCPServer.descriptions[name] != nil)
            #expect(!MCPServer.short.contains(name))
        }
    }
}
