import AppKit
import PDFKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentSealTests {
    private var browser: Browser!
    private var socket: AgentSocket!
    private var server: LocalPageServer!
    private var made: [UUID] = []
    private let secret = "Sw0rd fish@9+&\"<x"

    private static let style = "<style>body{margin:0;background:#fff;color:#fff} input{display:block;width:760px;height:100px;font-size:90px;border:0;outline:0;padding:0;margin:0;color:#000;background:#fff} button{position:absolute;top:400px}</style>"
    private static let form = "<!doctype html><title>Sign in</title>" + style
        + "<form action='/landed' method='get'><input id=p name=pw type=password><input name=email autocomplete=username style='color:#fff'><input name=card_number value=4111111111111111 style='color:#fff'><button>Go</button></form><div style='position:absolute;top:600px;color:#000'>Plainword</div>"
        + "<script>function swap(){var p=document.getElementById('p');var t=document.createElement('input');t.id='p';t.name='pw';t.type='text';t.value=p.value;p.replaceWith(t)}</script>"
    private static let landed = "<!doctype html><title>Landed</title>" + style
        + "<p id=echo style='color:#000;font-size:90px;margin:0;height:100px'>x</p><div style='position:absolute;top:600px;color:#000'>Plainword</div>"
        + "<script>var q=new URLSearchParams(location.search).get('pw');document.title='Hello '+q;echo.textContent=q;"
        + "console.log('pw is '+q);fetch('/ping?pw='+encodeURIComponent(q)).catch(function(){})</script>"

    init() throws {
        keepSetting(Shared.prefs, \.agentMode, "agents.mode")
        keepSetting(Shared.prefs, \.agentsOn, "agents.on")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        let mine = Tab(configuration: Web.configuration(space: browser.spaceID))
        mine.restore(url: URL(string: "https://example.com/mine")!, title: "Mine")
        browser.showRow([mine], active: mine.id)
        socket = AgentSocket()
        socket.box.browser = browser
        browser.prefs.agentMode = .auto
        browser.prefs.agentsOn = true
        AgentSites.shared.reset()
        server = try LocalPageServer([
            "/form": .init(type: "text/html", body: Self.form),
            "/landed": .init(type: "text/html", body: Self.landed),
            "/ping": .init(type: "text/plain", body: "ok"),
        ])
    }

    private func tearDown() {
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        for id in made {
            TaskLedger.shared.close(id)
            AgentLinks.shared.forget(id)
        }
        AgentWorkTabs.forget()
        AgentSites.shared.reset()
        server?.stop()
        browser?.closeAll()
        browser = nil
    }

    private func session() -> UUID {
        let link = AgentLinks.shared.join(.named(UUID().uuidString), name: "Claude Code")
        TaskLedger.shared.open(link.id, title: "Claude Code")
        made.append(link.id)
        return link.id
    }

    private func call(_ name: String, _ arguments: [String: Any] = [:], _ link: UUID) async -> ToolOutcome {
        await socket.session(name, arguments, task: link, browser: browser).outcome
    }

    private func signedIn(_ link: UUID) async throws -> (tab: Tab, id: String) {
        let opened = await call("open", ["url": "http://127.0.0.1:\(server.port)/form"], link)
        let id = try #require(ToolReply.data(opened)["id"] as? String)
        let tab = try #require(socket.box.find(["tab": id])?.tab)
        _ = await call("wait", ["tab": id], link)
        socket.box.logins = { [port = Int(server.port)] in [Kept(host: $0, user: "sam@example.com", used: nil, clear: true, port: port)] }
        socket.box.loginSecret = { [secret] in Login(host: $0.host, user: $0.user, password: secret, used: nil, clear: true) }
        let filled = await socket.box.signIn(tab, account: nil)
        #expect(!filled.failed, "\(filled.text ?? "")")
        return (tab, id)
    }

    private func written(_ said: ToolOutcome) -> String {
        let data = said.data.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return [said.text ?? "", said.plain ?? "", said.hint ?? "", data].joined(separator: "\n")
    }

    private var forms: [String] {
        var query = CharacterSet.alphanumerics
        query.insert(charactersIn: "-._~")
        let percent = secret.addingPercentEncoding(withAllowedCharacters: query) ?? secret
        return [secret, percent, percent.replacingOccurrences(of: "%20", with: "+"), "Sw0rd fish@9"]
    }

    private func dark(_ png: Data?, rows: Int) throws -> Int {
        let picture = try #require(png.flatMap(NSBitmapImageRep.init(data:)))
        let scale = max(1, picture.pixelsWide / 1000)
        var dark = 0
        for x in stride(from: 0, to: min(picture.pixelsWide, 740 * scale), by: 2) {
            for y in stride(from: 0, to: min(picture.pixelsHigh, rows * scale), by: 2) {
                if let color = picture.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.brightnessComponent < 0.5 { dark += 1 }
            }
        }
        return dark
    }

    @Test func aFilledPasswordLeavesNoTraceInAnyAnswer() async throws {
        let link = session()
        let (tab, id) = try await signedIn(link)
        _ = try await tab.web.evaluateJavaScript("document.forms[0].submit(); 1")
        for _ in 0..<400 where tab.title != "Hello " + secret { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(300))

        var said: [String: ToolOutcome] = [:]
        said["tab"] = await call("tab", [:], link)
        said["tabs"] = await call("tabs", [:], link)
        said["tabs all"] = await call("tabs", ["all": true], link)
        said["snapshot"] = await call("snapshot", ["tab": id], link)
        said["text"] = await call("text", ["tab": id], link)
        said["console"] = await call("console", ["tab": id], link)
        said["network"] = await call("network", ["tab": id], link)
        said["wait"] = await call("wait", ["tab": id, "text": "nothing here", "seconds": 0.05], link)
        said["navigate"] = await call("navigate", ["tab": id, "url": "http://127.0.0.1:\(server.port)/landed?pw=" + (forms[1])], link)

        #expect(tab.title == "Hello " + secret)
        #expect(tab.sealed.contains(secret))
        for (name, outcome) in said {
            let words = written(outcome)
            for form in forms {
                #expect(!words.contains(form), "\(name) shows \(form): \(words)")
            }
        }
    }

    @Test func aPasswordBoxSwappedForATextBoxIsNotPictured() async throws {
        let link = session()
        let (tab, id) = try await signedIn(link)
        _ = try await tab.web.evaluateJavaScript("swap(); document.getElementById('p').type")

        let shot = await call("screenshot", ["tab": id], link)
        let part = await call("screenshot", ["tab": id, "full": true], link)
        let after = try await tab.web.evaluateJavaScript("!document.querySelector('[data-broadway-secret]') && document.getElementById('p').style.color === ''") as? Bool

        #expect(try dark(shot.imagePNG, rows: 100) == 0)
        #expect(try dark(part.imagePNG, rows: 100) == 0)
        #expect(after == true)
    }

    @Test func tilesAndMarksPictureNoSecretEither() async throws {
        let link = session()
        let (tab, id) = try await signedIn(link)
        _ = try await tab.web.evaluateJavaScript("swap(); document.getElementById('p').type")

        let tiles = await call("screenshot", ["tab": id, "tiles": true], link)
        let marked = await call("screenshot", ["tab": id, "marks": true], link)
        let both = await call("screenshot", ["tab": id, "tiles": true, "marks": true, "width": 500], link)
        let after = try await tab.web.evaluateJavaScript("!document.querySelector('[data-broadway-secret]') && document.getElementById('p').style.color === ''") as? Bool

        #expect(!tiles.failed && !tiles.pictures.isEmpty, "\(tiles.text ?? "")")
        for picture in tiles.pictures { #expect(try dark(picture, rows: 100) == 0) }
        #expect(try dark(marked.imagePNG, rows: 100) == 0)
        #expect(!both.pictures.isEmpty)
        for picture in both.pictures { #expect(try dark(picture, rows: 50) == 0) }
        #expect(after == true)
    }

    @Test func aSealedValueTheSiteEchoesIsNotPictured() async throws {
        let link = session()
        let (tab, id) = try await signedIn(link)
        _ = try await tab.web.evaluateJavaScript("document.forms[0].submit(); 1")
        for _ in 0..<400 where tab.title != "Hello " + secret { try await Task.sleep(for: .milliseconds(10)) }

        let shot = await call("screenshot", ["tab": id], link)
        let color = try await tab.web.evaluateJavaScript("document.getElementById('echo').style.color") as? String

        #expect(try dark(shot.imagePNG, rows: 100) == 0)
        #expect(color == "rgb(0, 0, 0)")
    }

    @Test func aPDFHoldsNoSecretValueInItsText() async throws {
        let link = session()
        let (tab, _) = try await signedIn(link)
        _ = try await tab.web.evaluateJavaScript("swap(); 1")
        let swapped = try await PersonPages.pdf(tab)
        _ = try await tab.web.evaluateJavaScript("document.forms[0].submit(); 1")
        for _ in 0..<400 where tab.title != "Hello " + secret { try await Task.sleep(for: .milliseconds(10)) }
        let echoed = try await PersonPages.pdf(tab)

        for made in [swapped, echoed] {
            let words = PDFDocument(data: made)?.string ?? ""
            #expect(words.contains("Plainword"), "\(words)")
            #expect(!words.contains("Sw0rd"), "\(words)")
            #expect(!words.contains("4111"), "\(words)")
        }
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct AgentSealsKeptTests {
    @Test func aSealOutlivesItsTab() {
        var tab: Tab? = Tab(configuration: Web.configuration(space: UUID()))
        tab?.seal("Kept-After-Close-91")
        tab?.seal("abc")
        tab = nil

        #expect(AgentSeals.all.contains("Kept-After-Close-91"))
        #expect(!AgentSeals.all.contains("abc"))
        #expect(AgentSecrets.scrub("Hello Kept-After-Close-91", sealed: AgentSeals.all) == "Hello ••••")
    }
}
