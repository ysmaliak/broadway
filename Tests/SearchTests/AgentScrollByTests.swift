import AppKit
import WebKit
import Testing
@testable import Search
@testable import BroadwayCLI

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct AgentScrollByTests {
    static let long = """
    <!doctype html><html lang="en"><title>Long</title><body style="margin:0"><h1>Long</h1>
    <div style="height:5000px"></div><p>End words</p></body></html>
    """
    static let growing = """
    <!doctype html><html lang="en"><title>Grows</title><body style="margin:0"><h1>Grows</h1>
    <div id="feed"><div style="height:3000px"></div></div>
    <script>
    var added = 0;
    addEventListener('scroll', function () {
      if (added || innerHeight + scrollY < document.documentElement.scrollHeight - 50) return;
      added = 1;
      setTimeout(function () { var more = document.createElement('div'); more.style.height = '3000px'; more.textContent = 'More came'; document.getElementById('feed').appendChild(more); }, 150);
    });
    </script></body></html>
    """
    static let inner = """
    <!doctype html><html lang="en"><title>App</title>
    <body style="margin:0;height:100vh;overflow:hidden">
    <main id="main" style="height:100vh;overflow-y:auto"><h1>App</h1><div style="height:5000px"></div><p>Last line</p></main>
    </body></html>
    """

    let browser: Browser
    let box = BrowserToolbox()
    let server: LocalPageServer
    let task = UUID()

    init() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        box.browser = browser
        browser.prefs.agentMode = .auto
        server = try LocalPageServer(["/long": .init(type: "text/html", body: Self.long),
                                      "/growing": .init(type: "text/html", body: Self.growing),
                                      "/inner": .init(type: "text/html", body: Self.inner)])
    }

    func open(_ path: String) async throws -> (Tab, String) {
        _ = await box.call("open", ["url": server.url(path).absoluteString], task: task)
        let tab = try #require(browser.tabs.first { $0.agent })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id], task: task)
        return (tab, id)
    }

    func number(_ tab: Tab, _ script: String) async -> Double {
        let found = await PageSelection.run(tab, script)
        return (found as? NSNumber)?.doubleValue ?? -1
    }

    func finish() {
        AgentDesk.shared.drop(task: task)
        server.stop()
        browser.closeAll()
    }

    func scrollCommand() throws -> BroadwayCLI.Command {
        let found = try #require(AgentCatalog.commands(BrowserToolbox().tools).first { $0["name"] as? String == "scroll" })
        return BroadwayCLI.Command(found)
    }

    @Test func aDirectionAndPointsAreOneScrollOnTheCommandLine() throws {
        let scroll = try scrollCommand()

        #expect(try CommandLineInput.parse(scroll, ["down", "800"])["by"] as? String == "down 800")
        #expect(try CommandLineInput.parse(scroll, ["up", "300"])["by"] as? String == "up 300")
        #expect(try CommandLineInput.parse(scroll, ["down"])["by"] as? String == "down")
        #expect(try CommandLineInput.parse(scroll, ["-300"])["by"] as? String == "-300")
        #expect(try CommandLineInput.parse(scroll, ["bottom"])["by"] as? String == "bottom")
    }

    @Test func eachWayOfSayingHowFarIsRead() {
        #expect(AgentScrolling.amount("down 800") == .init(mode: "down", points: 800))
        #expect(AgentScrolling.amount("up 300") == .init(mode: "up", points: 300))
        #expect(AgentScrolling.amount("800") == .init(mode: "down", points: 800))
        #expect(AgentScrolling.amount("-300") == .init(mode: "up", points: 300))
        #expect(AgentScrolling.amount(-300.0) == .init(mode: "up", points: 300))
        #expect(AgentScrolling.amount("down") == .init(mode: "down", points: 0))
        #expect(AgentScrolling.amount("Top") == .init(mode: "top", points: 0))
        #expect(AgentScrolling.amount("bottom") == .init(mode: "bottom", points: 0))
        #expect(AgentScrolling.amount("Save") == nil)
        #expect(AgentScrolling.amount("down lots") == nil)
    }

    @Test func downWithPointsMovesThatFarAndSaysHowMuchIsLeft() async throws {
        defer { finish() }
        let (tab, id) = try await open("/long")

        let said = await box.call("scroll", ["tab": id, "by": "down 800"], task: task)

        #expect(!said.failed, "\(said.text ?? "")")
        #expect(await number(tab, "return scrollY;") == 800)
        #expect(said.text?.contains("Scrolled down 800 points") == true, "\(said.text ?? "")")
        #expect(said.text?.contains("more below") == true, "\(said.text ?? "")")
        #expect(said.data?["bottom"] as? Bool == false)
    }

    @Test func upPointsAndNegativePointsGoBackUp() async throws {
        defer { finish() }
        let (tab, id) = try await open("/long")
        _ = await box.call("scroll", ["tab": id, "by": "down 800"], task: task)

        let up = await box.call("scroll", ["tab": id, "by": "up 300"], task: task)
        #expect(await number(tab, "return scrollY;") == 500)
        #expect(up.text?.contains("Scrolled up 300 points") == true, "\(up.text ?? "")")
        let back = await box.call("scroll", ["tab": id, "by": "-200"], task: task)
        #expect(await number(tab, "return scrollY;") == 300, "\(back.text ?? "")")
        let top = await box.call("scroll", ["tab": id, "by": "top"], task: task)
        #expect(await number(tab, "return scrollY;") == 0)
        #expect(top.text?.contains("Scrolled to the top") == true, "\(top.text ?? "")")
    }

    @Test func reachingTheEndSaysItIsAtTheBottom() async throws {
        defer { finish() }
        let (_, id) = try await open("/long")

        let far = await box.call("scroll", ["tab": id, "by": "down 99999"], task: task)
        #expect(far.text?.contains("at the bottom") == true, "\(far.text ?? "")")
        #expect(far.data?["bottom"] as? Bool == true)
        let again = await box.call("scroll", ["tab": id, "by": "down 800"], task: task)
        #expect(again.text?.contains("Already at the bottom") == true, "\(again.text ?? "")")
    }

    @Test func aPageThatGrowsAsItScrollsIsNotCalledEnded() async throws {
        defer { finish() }
        let (_, id) = try await open("/growing")

        let said = await box.call("scroll", ["tab": id, "by": "bottom"], task: task)

        #expect(!said.failed, "\(said.text ?? "")")
        #expect(said.text?.contains("at the bottom") == false, "\(said.text ?? "")")
        #expect(said.text?.contains("loaded more") == true, "\(said.text ?? "")")
        #expect(said.data?["bottom"] as? Bool == false)
    }

    @Test func aPageThatScrollsInItsMainBoxMovesThatBox() async throws {
        defer { finish() }
        let (tab, id) = try await open("/inner")

        let said = await box.call("scroll", ["tab": id, "by": "down 800"], task: task)

        #expect(!said.failed, "\(said.text ?? "")")
        #expect(await number(tab, "return document.getElementById('main').scrollTop;") == 800)
        #expect(said.text?.contains("Already at the bottom") == false, "\(said.text ?? "")")
        #expect(said.text?.contains("800 points") == true, "\(said.text ?? "")")
    }
}
