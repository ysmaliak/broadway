import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FormFillTests {
    private final class Page: FormPageAccess {
        var listed: [FormField] = []
        var applied: [FormValue] = []
        var undone = 0

        func fields() async -> [FormField] { listed }

        func apply(_ values: [FormValue], fields: [FormField]) async -> FormApplied {
            applied = values
            return FormApplied(filled: values.count, missed: 0)
        }

        func undo() async { undone += 1 }
    }

    private var browser: Browser!
    private var keeper: MemoryKeeper!
    private var forms: FormFill!
    private var page: Page!

    init() {
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        keeper = MemoryKeeper()
        let book = AutofillBook(keeper: keeper)
        forms = FormFill(book: book)
        forms.browser = browser
        page = Page()
        forms.pageFor = { [unowned self] _ in page }
        var profile = AutofillProfile()
        profile.name = "Ada Lovelace"
        book.save(profile: profile)
        book.save(card: CardSecret(number: "4242424242424242", expiry: CardExpiry(month: 12, year: 2029)!, holder: "Ada", securityCode: "737"))
        page.listed = [FormField(index: 0, autocomplete: "name"), FormField(index: 1, autocomplete: "cc-number"), FormField(index: 2, autocomplete: "cc-csc")]
    }

    private func tearDown() {
        browser?.closeAll()
        browser = nil
    }

    private func tab(_ address: String, shy: Bool = false) -> Tab {
        let tab = Tab(shy: shy, configuration: Web.configuration(shy: shy, space: browser.spaceID))
        tab.restore(url: URL(string: address)!, title: "Shop")
        browser.showRow([tab], active: tab.id)
        return tab
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test func nothingGoesInUntilYouSaySo() async {
        let tab = tab("https://shop.example/pay")
        forms.book.prove = { _, done in done(true) }

        await forms.prepare(tab, page)

        #expect(forms.preview != nil)
        #expect(page.applied.isEmpty)
    }

    @Test func aCardGoesInOnlyAfterProof() async {
        let tab = tab("https://shop.example/pay")
        var proved = 0
        forms.book.prove = { _, done in
            proved += 1
            done(true)
        }
        await forms.prepare(tab, page)

        forms.confirm()
        await settle()

        #expect(proved == 1)
        #expect(page.applied.map(\.value) == ["Ada Lovelace", "4242424242424242", "737"])
        #expect(forms.done?.filled == 3)
    }

    @Test func aRefusedProofFillsNothingAtAll() async {
        let tab = tab("https://shop.example/pay")
        forms.book.prove = { _, done in done(false) }
        await forms.prepare(tab, page)
        let reads = keeper.reads

        forms.confirm()
        await settle()

        #expect(page.applied.isEmpty)
        #expect(keeper.reads == reads)
        #expect(forms.done == nil)
    }

    @Test func aPrivateTabIsAskedFirst() async {
        let tab = tab("https://shop.example/pay", shy: true)
        forms.book.prove = { _, done in done(true) }
        var asked = 0
        forms.askPrivate = { _ in asked += 1 }
        await forms.prepare(tab, page)

        forms.confirm()
        await settle()

        #expect(asked == 1)
        #expect(page.applied.isEmpty)
    }

    @Test func aPrivateTabFillsOnceYouSayYes() async {
        let tab = tab("https://shop.example/pay", shy: true)
        forms.book.prove = { _, done in done(true) }
        forms.askPrivate = { go in go() }
        await forms.prepare(tab, page)

        forms.confirm()
        await settle()

        #expect(page.applied.count == 3)
    }

    @Test func anInsecurePageNeverReachesTheCard() async {
        let tab = tab("http://shop.example/pay")
        var proved = 0
        forms.book.prove = { _, done in
            proved += 1
            done(true)
        }
        await forms.prepare(tab, page)

        forms.confirm()
        await settle()

        #expect(proved == 0)
        #expect(page.applied.map(\.value) == ["Ada Lovelace"])
    }

    @Test func aPageThatMovedOnGetsNothing() async {
        let tab = tab("https://shop.example/pay")
        forms.book.prove = { _, done in done(true) }
        await forms.prepare(tab, page)

        tab.restore(url: URL(string: "https://elsewhere.example/")!, title: "Elsewhere")
        forms.confirm()
        await settle()

        #expect(page.applied.isEmpty)
        #expect(forms.preview == nil)
    }

    @Test func theSwitchTurnsItAllOff() async {
        _ = tab("https://shop.example/pay")
        keepSetting(forms.book, \.fillsForms, "autofill.forms")
        forms.book.fillsForms = false

        forms.begin()
        await settle()

        #expect(forms.preview == nil)
    }

    @Test func undoReachesThePageAndTheBarGoes() async {
        let tab = tab("https://shop.example/pay")
        forms.book.prove = { _, done in done(true) }
        await forms.prepare(tab, page)
        forms.confirm()
        await settle()

        forms.undo()
        await settle()

        #expect(page.undone == 1)
        #expect(forms.done == nil)
    }

    @Test func typingEndsTheChanceToUndo() async {
        let tab = tab("https://shop.example/pay")
        forms.book.prove = { _, done in done(true) }
        await forms.prepare(tab, page)
        forms.confirm()
        await settle()

        forms.heard(.typed, from: tab)

        #expect(forms.done == nil)
    }

    @Test func aSentCardIsOfferedOnceTheFormHasGone() async {
        let tab = tab("https://shop.example/pay")
        forms.pause = { _ in }
        let fields = [FormField(index: 0, autocomplete: "cc-number"), FormField(index: 1, autocomplete: "cc-exp")]

        forms.heard(.sent(fields, values: [":0": "5555555555554444", ":1": "11/30"]), from: tab)
        await settle()

        #expect(forms.offer?.keep.question == "Keep your Mastercard ending 4444?")
        forms.keepOffer()
        #expect(forms.book.cards.count == 2)
    }

    @Test func aKnownCardIsNotOfferedAgain() async {
        let tab = tab("https://shop.example/pay")
        forms.pause = { _ in }
        let fields = [FormField(index: 0, autocomplete: "cc-number"), FormField(index: 1, autocomplete: "cc-exp")]

        forms.heard(.sent(fields, values: [":0": "4242424242424242", ":1": "12/29"]), from: tab)
        await settle()

        #expect(forms.offer == nil)
    }

    @Test func noSaveFromAPrivateTabOrAnInsecurePage() async {
        forms.pause = { _ in }
        let fields = [FormField(index: 0, autocomplete: "cc-number"), FormField(index: 1, autocomplete: "cc-exp")]
        let values = [":0": "5555555555554444", ":1": "11/30"]

        forms.heard(.sent(fields, values: values), from: tab("https://shop.example/pay", shy: true))
        forms.heard(.sent(fields, values: values), from: tab("http://shop.example/pay"))
        await settle()

        #expect(forms.offer == nil)
    }

    @Test func theHintIsForFormsNotSingleBoxes() {
        let tab = tab("https://shop.example/pay")

        #expect(forms.hint(for: tab, field: FormField(autocomplete: "name", count: 5)) == "Your profile")
        #expect(forms.hint(for: tab, field: FormField(autocomplete: "cc-number", count: 5)) == "Visa ···· 4242")
        #expect(forms.hint(for: tab, field: FormField(autocomplete: "name", count: 1)) == nil)
        #expect(forms.hint(for: tab, field: FormField(label: "Date of birth", count: 5)) == nil)
        #expect(forms.hint(for: tab, field: nil) == nil)
    }

    @Test func noCardHintOnAnInsecurePage() {
        let tab = tab("http://shop.example/pay")

        #expect(forms.hint(for: tab, field: FormField(autocomplete: "cc-number", count: 5)) == nil)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class WebFormPageTests {
    private static let checkout = """
    <!doctype html><body>
    <form id="find"><input name="q" type="search"></form>
    <form id="pay">
      <label for="n">Full name</label><input id="n" autocomplete="name">
      <input id="e" type="email" name="email">
      <input id="a" autocomplete="address-line1">
      <select id="s" name="state"><option value="">Pick</option><option value="CA">California</option></select>
      <input id="p" type="password" name="password">
      <input id="x" name="coupon" value="KEEP">
      <input id="c" autocomplete="cc-number">
      <input id="d" autocomplete="cc-exp" placeholder="MM / YY">
      <button type="submit">Pay</button>
    </form>
    <input id="hidden" type="hidden" name="city">
    <script>
      window.events = [];
      document.addEventListener('submit', function (e) { e.preventDefault(); window.events.push('submit'); });
      document.getElementById('n').addEventListener('input', function () { window.events.push('input'); });
    </script>
    </body>
    """

    private var holding: [NSObject] = []

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    private func tearDown() async {
        holding = []
    }

    private func page(_ html: String, at address: String = "https://shop.example/pay") async throws -> (WKWebView, WebFormPage, FieldRelay) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let relay = FieldRelay()
        configuration.userContentController.add(relay, contentWorld: Web.world, name: FormFieldScript.relay)
        configuration.userContentController.addUserScript(
            WKUserScript(source: FormFieldScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Web.world))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
        let loaded = Loaded()
        holding += [loaded, relay, web]
        web.navigationDelegate = loaded
        web.loadHTMLString(html, baseURL: URL(string: address))
        try await loaded.wait()
        return (web, WebFormPage(web: web, relay: relay), relay)
    }

    private func value(_ web: WKWebView, _ selector: String) async throws -> Any? {
        try await web.evaluateJavaScript("document.querySelector('\(selector)').value")
    }

    @Test func thePageDescribesItsBoxesWithoutTheirContents() async throws {
        let (_, page, _) = try await page(Self.checkout)

        let fields = await page.fields()

        #expect(fields.filter { $0.group == 2 }.count == 8)
        #expect(fields.first { $0.name == "city" } == nil)
        #expect(fields.first { $0.htmlID == "n" }?.label == "Full name")
        #expect(fields.first { $0.name == "state" }?.options.count == 2)
        #expect(fields.first { $0.name == "coupon" }?.filled == true)
        #expect(!"\(fields)".contains("KEEP"))
    }

    @Test func aFillGoesThroughThePlanAndNeverSubmits() async throws {
        let (web, page, _) = try await page(Self.checkout)
        let fields = await page.fields()
        var profile = AutofillProfile()
        profile.name = "Ada Lovelace"
        profile.email = "ada@example.com"
        let address = AutofillAddress(line1: "1 Main Street", region: "California")
        let card = CardRow(id: "c", label: "", network: .visa, last: "4242")
        let plan = FormPlanner.plan(fields, page: URL(string: "https://shop.example/pay"), privateTab: false,
                                    sources: FormSources(profile: profile, address: address, card: card))
        let secret = CardSecret(number: "4242424242424242", expiry: CardExpiry(month: 12, year: 2029)!)

        let applied = await page.apply(FormPlanner.values(plan, card: secret), fields: plan.fields)

        #expect(plan.summary == "6 of 8 · 2 stay yours")
        #expect(applied == FormApplied(filled: 6, missed: 0))
        let name = try await value(web, "#n") as? String
        let state = try await value(web, "#s") as? String
        let number = try await value(web, "#c") as? String
        let expiry = try await value(web, "#d") as? String
        let coupon = try await value(web, "#x") as? String
        let password = try await value(web, "#p") as? String
        #expect(name == "Ada Lovelace")
        #expect(state == "CA")
        #expect(number == "4242424242424242")
        #expect(expiry == "12 / 29")
        #expect(coupon == "KEEP")
        #expect(password == "")
        let events = try await web.evaluateJavaScript("window.events") as? [String]
        #expect(events == ["input"])
    }

    @Test func aFillMarksTheBoxAndUndoPutsItAllBack() async throws {
        let (web, page, _) = try await page(Self.checkout)
        let fields = await page.fields()
        let name = try #require(fields.first { $0.htmlID == "n" })
        let state = try #require(fields.first { $0.name == "state" })

        _ = await page.apply([FormValue(fieldID: name.id, value: "Ada", source: .profile),
                              FormValue(fieldID: state.id, value: "CA", source: .address)], fields: fields)
        let marked = try await web.evaluateJavaScript("document.querySelector('#n').style.backgroundImage") as? String
        await page.undo()

        #expect(marked?.contains("radial-gradient") == true)
        let back = try await value(web, "#n") as? String
        let backState = try await value(web, "#s") as? String
        let after = try await web.evaluateJavaScript("document.querySelector('#n').style.backgroundImage") as? String
        #expect(back == "")
        #expect(backState == "")
        #expect(after == "")
    }

    @Test func aBoxThatGainedAValueMeanwhileIsLeftAlone() async throws {
        let (web, page, _) = try await page(Self.checkout)
        let fields = await page.fields()
        let name = try #require(fields.first { $0.htmlID == "n" })
        _ = try await web.evaluateJavaScript("document.querySelector('#n').value = 'Typed'; 1")

        let applied = await page.apply([FormValue(fieldID: name.id, value: "Ada", source: .profile)], fields: fields)

        #expect(applied == FormApplied(filled: 0, missed: 1))
        let kept = try await value(web, "#n") as? String
        #expect(kept == "Typed")
    }

    @Test func aDocumentFromAnotherOriginGetsNothing() async throws {
        let (web, page, _) = try await page(Self.checkout)
        var fields = await page.fields()
        fields = fields.map {
            var field = $0
            field.origin = "https://elsewhere.example"
            return field
        }
        let name = try #require(fields.first { $0.htmlID == "n" })

        let applied = await page.apply([FormValue(fieldID: name.id, value: "Ada", source: .profile)], fields: fields)

        #expect(applied.filled == 0)
        let kept = try await value(web, "#n") as? String
        #expect(kept == "")
    }

    @Test func aPageCannotReachTheScript() async throws {
        let (web, _, _) = try await page(Self.checkout)

        let seen = try await web.evaluateJavaScript("typeof window.__broadwayFields")

        #expect((seen as? String) == "undefined")
    }

    @Test func aFrameFromAnotherOriginIsFilledInItsOwnDocument() async throws {
        let server = try LocalPageServer(["/card": .init(type: "text/html", body: """
        <!doctype html><input id="cc" name="cardnumber" autocomplete="cc-number" style="width:200px;height:30px">
        """)])
        defer { server.stop() }
        let html = "<!doctype html><form><input id='n' autocomplete='name'><iframe src='http://127.0.0.1:\(server.port)/card' width='300' height='80'></iframe></form>"
        let (web, page, relay) = try await page(html, at: "http://localhost:\(server.port)/pay")
        for _ in 0..<100 where relay.frames.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(relay.frames.count == 1)

        let fields = await page.fields()
        let card = try #require(fields.first { $0.autocomplete == "cc-number" })
        let applied = await page.apply([FormValue(fieldID: card.id, value: "4242424242424242", source: .card)], fields: fields)

        #expect(!card.frame.isEmpty)
        #expect(card.origin == "http://127.0.0.1:\(server.port)")
        #expect(applied.filled == 1)
        let outer = try await value(web, "#n") as? String
        #expect(outer == "")
    }

    @Test func theCaretGoesToTheFirstBoxLeftEmpty() async throws {
        let (web, page, _) = try await page("<!doctype html><form><input id='a' autocomplete='name'><input id='b' name='other'><input id='c' autocomplete='email'></form>")
        let fields = await page.fields()

        _ = await page.apply([FormValue(fieldID: fields[0].id, value: "Ada", source: .profile),
                              FormValue(fieldID: fields[2].id, value: "a@b.c", source: .profile)], fields: fields)

        let active = try await web.evaluateJavaScript("document.activeElement.id") as? String
        #expect(active == "b")
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var done = false

        func wait() async throws {
            if done { return }
            try await withCheckedThrowingContinuation { self.continuation = $0 }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done = true
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            done = true
            continuation?.resume(throwing: error)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            done = true
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
