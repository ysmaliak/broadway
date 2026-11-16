import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct CodeFinderTests {
    @Test func theCodesPeopleActuallyGetAreFound() {
        let samples: [(String, String)] = [
            ("Your verification code is 482913. Do not share it.", "482913"),
            ("G-482913 is your Google verification code.", "482913"),
            ("Your Uber code: 1234", "1234"),
            ("123 456 is your Instagram code.", "123456"),
            ("Use 739-201 to sign in", "739201"),
            ("Your login code is A7K2Q9", "A7K2Q9"),
            ("Tu código de acceso es 884512", "884512"),
            ("验证码：551034，请勿泄露", "551034"),
            ("Your order 99887766 needs a code: 5521", "5521"),
        ]

        for (text, code) in samples {
            #expect(CodeFinder.code(in: text) == code, "\(text)")
        }
    }

    @Test func whatOnlyLooksLikeACodeIsLeftAlone() {
        let samples = [
            "Your order 482913 has shipped.",
            "See you at 12:30 tomorrow",
            "Pay $1234 by Friday",
            "Call me on 5551234",
            "50% off with code SAVE50, this weekend only. Reply STOP to unsubscribe",
            "In 2026 we changed our code of conduct",
            "The total was 1,234.56",
            "",
        ]

        for text in samples {
            #expect(CodeFinder.code(in: text) == nil, "\(text)")
        }
    }

    @Test func printingOneNeverShowsIt() {
        let code = OneTimeCode(code: "482913", sender: "Bank", at: Date())

        let printed = "\(code) \(String(reflecting: code))"

        #expect(!printed.contains("482913"))
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class CodeWatchTests {
    private final class Fake: CodeSource {
        var answers: [CodeRead]
        var asked = 0

        init(_ answers: [CodeRead]) { self.answers = answers }

        func read(since: Date) async -> CodeRead {
            asked += 1
            return answers.isEmpty ? .nothing : answers.removeFirst()
        }
    }

    private var browser: Browser!
    private var watch: CodeWatch!
    private let code = OneTimeCode(code: "482913", sender: "Bank", at: Date())
    private let box = FormField(autocomplete: "one-time-code")

    init() {
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        watch = CodeWatch(book: AutofillBook(keeper: MemoryKeeper()))
        watch.browser = browser
        watch.pause = { _ in await Task.yield() }
        watch.mayRead = { _ in true }
    }

    private func tearDown() {
        watch.stop()
        browser?.closeAll()
        browser = nil
    }

    private func tab(_ address: String, shy: Bool = false) -> Tab {
        let tab = Tab(shy: shy, configuration: Web.configuration(shy: shy, space: browser.spaceID))
        tab.restore(url: URL(string: address)!, title: "Site")
        browser.showRow([tab], active: tab.id)
        return tab
    }

    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
    }

    @Test func aCodeBoxLooksAndOffersWhatItFinds() async {
        let tab = tab("https://bank.example/verify")
        let source = Fake([.found([code])])
        watch.sources = { _ in [source] }

        watch.focused(on: tab, field: box)
        await settle()

        #expect(watch.offers(on: tab) == [code])
        #expect(source.asked == 1)
    }

    @Test func anOrdinaryBoxNeverLooks() async {
        let tab = tab("https://bank.example/verify")
        let source = Fake([.found([code])])
        watch.sources = { _ in [source] }

        watch.focused(on: tab, field: FormField(label: "Your city"))
        watch.focused(on: tab, field: nil)
        await settle()

        #expect(source.asked == 0)
    }

    @Test func anInsecurePageOrPrivateTabNeverLooks() async {
        let source = Fake([.found([code])])
        watch.sources = { _ in [source] }

        watch.focused(on: tab("http://bank.example/verify"), field: box)
        await settle()
        watch.focused(on: tab("https://bank.example/verify", shy: true), field: box)
        await settle()

        #expect(source.asked == 0)
    }

    @Test func aBoxInsideAFrameNeverLooks() async {
        let tab = tab("https://bank.example/verify")
        tab.fieldFrameHost = "ads.example"
        let source = Fake([.found([code])])
        watch.sources = { _ in [source] }

        watch.focused(on: tab, field: box)
        await settle()

        #expect(source.asked == 0)
    }

    @Test func aTabBehindOrAWindowBehindNeverLooks() async {
        let tab = tab("https://bank.example/verify")
        let source = Fake([.found([code])])
        watch.sources = { _ in [source] }
        watch.mayRead = { _ in false }

        watch.focused(on: tab, field: box)
        await settle()

        #expect(source.asked == 0)
    }

    @Test func itKeepsLookingWhileTheCaretStaysAndStopsWhenItLeaves() async {
        let tab = tab("https://bank.example/verify")
        let source = Fake([.nothing, .nothing, .found([code])])
        watch.sources = { _ in [source] }

        watch.focused(on: tab, field: box)
        await settle()
        let found = watch.offers(on: tab)
        watch.left(tab)

        #expect(found == [code])
        #expect(source.asked == 3)
        #expect(watch.offered.isEmpty)
    }

    @Test func leavingTheBoxForgetsTheCode() async {
        let tab = tab("https://bank.example/verify")
        watch.sources = { _ in [Fake([.found([self.code])])] }
        watch.focused(on: tab, field: box)
        await settle()

        watch.left(tab)

        #expect(watch.offers(on: tab).isEmpty)
    }

    @Test func itGivesUpAfterAMinuteAndAHalf() async {
        let tab = tab("https://bank.example/verify")
        let source = Fake([])
        watch.sources = { _ in [source] }

        watch.focused(on: tab, field: box)
        await settle()

        #expect(source.asked == CodeWatch.tries)
    }

    @Test func theNewestCodeComesFirst() async {
        let tab = tab("https://bank.example/verify")
        let older = OneTimeCode(code: "111111", sender: "A", at: Date().addingTimeInterval(-300))
        watch.sources = { _ in [Fake([.found([older, self.code])])] }

        watch.focused(on: tab, field: box)
        await settle()

        #expect(watch.offers(on: tab).map(\.code) == ["482913", "111111"])
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class CodeBoxTests {
    private var holding: [NSObject] = []

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    private func tearDown() async {
        holding = []
    }

    private func page(_ html: String) async throws -> (WKWebView, WebFormPage) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let relay = FieldRelay()
        configuration.userContentController.add(relay, contentWorld: Web.world, name: FormFieldScript.relay)
        configuration.userContentController.addUserScript(
            WKUserScript(source: FormFieldScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Web.world))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let done = Expectation(description: "loaded")
        let loaded = Loaded { done.fulfill() }
        holding += [loaded, relay, web]
        web.navigationDelegate = loaded
        web.loadHTMLString(html, baseURL: URL(string: "https://bank.example/verify"))
        await fulfillment(of: [done], timeout: 10)
        return (web, WebFormPage(web: web, relay: relay))
    }

    @Test func oneBoxTakesTheWholeCode() async throws {
        let (web, page) = try await page("<!doctype html><input id='c' autocomplete='one-time-code' autofocus>")
        _ = try await web.evaluateJavaScript("document.getElementById('c').focus(); 1")

        let worked = await page.put(code: "482913", origin: "https://bank.example")

        #expect(worked)
        let value = try await web.evaluateJavaScript("document.getElementById('c').value") as? String
        #expect(value == "482913")
    }

    @Test func aRowOfSingleBoxesTakesADigitEach() async throws {
        let boxes = (0..<6).map { "<input id='b\($0)' maxlength='1'>" }.joined()
        let (web, page) = try await page("<!doctype html><form>\(boxes)</form>")
        _ = try await web.evaluateJavaScript("document.getElementById('b0').focus(); 1")

        let worked = await page.put(code: "482913", origin: "https://bank.example")

        #expect(worked)
        let value = try await web.evaluateJavaScript("[0,1,2,3,4,5].map(function (i) { return document.getElementById('b' + i).value; }).join('')") as? String
        #expect(value == "482913")
    }

    @Test func anotherSitesPageGetsNothing() async throws {
        let (web, page) = try await page("<!doctype html><input id='c' autocomplete='one-time-code'>")
        _ = try await web.evaluateJavaScript("document.getElementById('c').focus(); 1")

        let worked = await page.put(code: "482913", origin: "https://elsewhere.example")

        #expect(!worked)
        let value = try await web.evaluateJavaScript("document.getElementById('c').value") as? String
        #expect(value == "")
    }

    @Test func enterIsHeldOnlyWhileTheBoxIsEmpty() async throws {
        let (web, page) = try await page("""
        <!doctype html><form onsubmit="window.sent = (window.sent || 0) + 1; return false"><input id='c' autocomplete='one-time-code'></form>
        """)
        _ = try await web.evaluateJavaScript("document.getElementById('c').focus(); 1")
        page.holdEnter(true)
        try await Task.sleep(for: .milliseconds(100))
        let holds = "return window.__broadwayFields.holdsEnter()"

        let whileEmpty = try await web.callAsyncJavaScript(holds, contentWorld: Web.world) as? Bool
        _ = try await web.evaluateJavaScript("document.getElementById('c').value = '111222'; 1")
        let onceTyped = try await web.callAsyncJavaScript(holds, contentWorld: Web.world) as? Bool

        #expect(whileEmpty == true)
        #expect(onceTyped == false)
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        let done: () -> Void
        init(_ done: @escaping () -> Void) { self.done = done }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
    }
}
