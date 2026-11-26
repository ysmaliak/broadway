import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FormAnswersTests {
    private final class Page: FormPageAccess {
        var listed: [FormField] = []
        var applied: [FormValue] = []

        func fields() async -> [FormField] { listed }

        func apply(_ values: [FormValue], fields: [FormField]) async -> FormApplied {
            applied = values
            return FormApplied(filled: values.count, missed: 0)
        }

        func undo() async {}
    }

    private var browser: Browser!
    private var keeper: MemoryKeeper!
    private var file: URL!
    private var answers: FormAnswers!
    private var forms: FormFill!
    private var page: Page!

    init() {
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        keeper = MemoryKeeper()
        file = Store.file("form-answers-\(UUID().uuidString)")
        answers = FormAnswers(file: file, keeper: keeper)
        forms = FormFill(book: AutofillBook(keeper: keeper), answers: answers)
        forms.browser = browser
        forms.pause = { _ in }
        page = Page()
        forms.pageFor = { [unowned self] _ in page }
    }

    private func tearDown() {
        browser?.closeAll()
        browser = nil
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    private func tab(_ address: String, shy: Bool = false) -> Tab {
        let tab = Tab(shy: shy, configuration: Web.configuration(shy: shy, space: browser.spaceID))
        tab.restore(url: URL(string: address)!, title: "Sign up")
        browser.showRow([tab], active: tab.id)
        return tab
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    private let project = FormField(index: 0, name: "project", label: "Project", count: 3)
    private let team = FormField(index: 1, name: "team", label: "Team", count: 3)

    private func send(_ fields: [FormField], _ values: [String: String], from tab: Tab) async {
        forms.heard(.answered(fields, values: values), from: tab)
        await settle()
    }

    @Test func aSentFormIsRememberedForItsSite() async {
        let tab = tab("https://www.signup.example/join")

        await send([project, team], [":0": "APX-7", ":1": "Blue"], from: tab)

        let kept = answers.answers(for: URL(string: "https://accounts.signup.example/")!)
        #expect(kept[FormMemory.meaning(project)!]?.value == "APX-7")
        #expect(kept[FormMemory.meaning(team)!]?.value == "Blue")
        #expect(answers.siteCount == 1)
    }

    @Test func secretsCardsAndCodesAreNeverRemembered() {
        let fields = [
            FormField(index: 0, type: "password", name: "pw", label: "Password"),
            FormField(index: 1, autocomplete: "cc-number", name: "card", label: "Card"),
            FormField(index: 2, autocomplete: "cc-csc", name: "cvc", label: "CVC"),
            FormField(index: 3, autocomplete: "cc-exp", name: "exp", label: "Expiry"),
            FormField(index: 4, autocomplete: "one-time-code", name: "otp", label: "Code"),
            FormField(index: 5, autocomplete: "off", name: "nick", label: "Nickname"),
            FormField(index: 6, autocomplete: "new-password", name: "fresh", label: "Choose one"),
            FormField(index: 7, autocomplete: "current-password", name: "old", label: "Current"),
            FormField(index: 8, type: "hidden", name: "token", label: "Token"),
            FormField(index: 9, type: "file", name: "cv", label: "Your CV"),
            FormField(index: 10, type: "search", name: "find", label: "Find"),
            FormField(index: 11, name: "q", label: "Look for"),
            FormField(index: 12, name: "pin", label: "PIN"),
        ]
        let values = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, "kept-\($0.index)") })

        let taken = FormMemory.taken(fields, values: values)

        #expect(taken.isEmpty)
    }

    @Test func aCardNumberTypedIntoAPlainBoxIsNotRemembered() {
        let field = FormField(index: 0, name: "reference", label: "Reference")

        let taken = FormMemory.taken([field], values: [field.id: "4242 4242 4242 4242"])

        #expect(taken.isEmpty)
    }

    @Test func anAnswerLongerThan120CharactersIsNotRemembered() {
        let long = String(repeating: "a", count: 121)
        let fits = String(repeating: "b", count: 120)

        let taken = FormMemory.taken([project, team], values: [project.id: long, team.id: fits])

        #expect(taken[FormMemory.meaning(project)!] == nil)
        #expect(taken[FormMemory.meaning(team)!]?.value == fits)
    }

    @Test func nothingIsRememberedInAPrivateWindow() async {
        let tab = tab("https://signup.example/join", shy: true)

        await send([project], [":0": "APX-7"], from: tab)

        #expect(answers.siteCount == 0)
    }

    @Test func theProfileKeepsItsBoxesAndARememberedAnswerFillsTheRest() async {
        var profile = AutofillProfile()
        profile.name = "Ada Lovelace"
        forms.book.save(profile: profile)
        let name = FormField(index: 2, autocomplete: "name", name: "who", label: "Name", count: 3)
        let tab = tab("https://signup.example/join")
        await send([project, name], [":0": "APX-7", ":2": "Somebody Else"], from: tab)
        page.listed = [project, name]

        await forms.prepare(tab, page)

        let rows = forms.preview?.plan.rows ?? []
        #expect(rows.map(\.source) == [.remembered, .profile])
        #expect(rows.map(\.shown) == ["APX-7", "Ada Lovelace"])
    }

    @Test func aRememberedAnswerWaitsUntilThePersonAsks() async {
        let tab = tab("https://signup.example/join")
        await send([project], [":0": "APX-7"], from: tab)
        page.listed = [project]

        await forms.prepare(tab, page)

        #expect(forms.preview?.plan.rows.first?.source == .remembered)
        #expect(page.applied.isEmpty)
    }

    @Test func anAnswerIsFoundByTheBoxsMeaningNotItsPlace() async {
        let tab = tab("https://signup.example/join")
        await send([project], [":0": "APX-7"], from: tab)
        page.listed = [FormField(index: 7, name: "project", label: "Project", count: 3)]

        await forms.prepare(tab, page)

        #expect(forms.preview?.plan.rows.map(\.value) == ["APX-7"])
    }

    @Test func anotherSiteIsNotGivenTheAnswers() async {
        await send([project], [":0": "APX-7"], from: tab("https://signup.example/join"))
        let other = tab("https://elsewhere.example/join")
        page.listed = [project]

        await forms.prepare(other, page)

        #expect(forms.preview == nil)
    }

    @Test func aMenuChoiceIsPutBackAsAnOptionTheMenuHas() async {
        let options = [FormField.Option(value: "", text: "Choose"), FormField.Option(value: "se", text: "Sweden")]
        let sent = FormField(index: 0, type: "select", name: "country", label: "Where you work", options: options, count: 3)
        let tab = tab("https://signup.example/join")
        await send([sent], [":0": "se"], from: tab)
        let renamed = [FormField.Option(value: "", text: "Choose"), FormField.Option(value: "SE-1", text: "Sweden")]
        page.listed = [FormField(index: 0, type: "select", name: "country", label: "Where you work", options: renamed, count: 3)]

        await forms.prepare(tab, page)

        #expect(forms.preview?.plan.rows.map(\.value) == ["SE-1"])
        #expect(forms.preview?.plan.rows.map(\.shown) == ["Sweden"])
    }

    @Test func theFileIsSealedAndReadsBackAfterARestart() async throws {
        await send([project], [":0": "APX-7"], from: tab("https://signup.example/join"))

        let written = try Data(contentsOf: file)
        let again = FormAnswers(file: file, keeper: keeper)
        await again.ready()

        #expect(!String(decoding: written, as: UTF8.self).contains("APX-7"))
        #expect(again.answers(for: URL(string: "https://signup.example/")!)[FormMemory.meaning(project)!]?.value == "APX-7")
    }

    @Test func forgetAllLeavesNothingBehind() async {
        await send([project], [":0": "APX-7"], from: tab("https://signup.example/join"))

        answers.forgetAll()
        let again = FormAnswers(file: file, keeper: keeper)
        await again.ready()

        #expect(answers.siteCount == 0)
        #expect(again.siteCount == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func clearHistoryForgetsTheAnswersToo() async {
        let shared = browser.forms.answers
        await shared.remember([FormMemory.meaning(project)!: FormAnswer(value: "APX-7", text: "APX-7")],
                              on: URL(string: "https://signup.example/join"))
        #expect(shared.siteCount > 0)

        browser.clearHistory()

        #expect(shared.siteCount == 0)
    }

    @Test func theHintNamesWhereARememberedAnswerComesFrom() async {
        let tab = tab("https://signup.example/join")
        await send([project], [":0": "APX-7"], from: tab)

        let hint = forms.hint(for: tab, field: project)

        #expect(hint == "Remembered from this site")
        #expect(forms.hint(for: tab, field: team) == nil)
    }

    @Test func theDotSaysRememberedFromThisSite() {
        #expect(FormSource.remembered.help == "Remembered from this site")
        #expect(FormSource.remembered.dot != FormSource.profile.dot)
    }

    @Test func forgetAllAsksAboutTheNumberOfSites() {
        #expect(FormAnswers.question(3) == "Forget the answers remembered for forms on 3 sites?")
        #expect(FormAnswers.sitesLine(0) == "Nothing remembered yet")
        #expect(FormAnswers.sitesLine(1) == "1 site")
        #expect(FormAnswers.sitesLine(4) == "4 sites")
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FormAnswersPageTests {
    private static let signup = """
    <!doctype html><body>
    <form id="join">
      <label for="project">Project</label><input id="project" name="project" value="APX-7">
      <input id="mail" type="email" name="email" value="ada@example.com">
      <select id="team" name="team"><option value="">Pick</option><option value="b" selected>Blue</option></select>
      <input id="pw" type="password" name="password" value="hunter22">
      <input id="card" autocomplete="cc-number" value="4242424242424242">
      <input id="otp" autocomplete="one-time-code" value="123456">
      <input id="nick" name="nick" autocomplete="off" value="adie">
      <input id="find" type="search" name="find" value="cats">
      <input id="note" type="hidden" name="note" value="secret">
      <button type="submit">Join</button>
    </form>
    <form id="quiet" autocomplete="off"><input name="project" value="QUIET"><button type="submit">Go</button></form>
    <script>document.addEventListener('submit', function (e) { e.preventDefault(); });</script>
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

    private func page() async throws -> (WKWebView, WebFormPage, FieldRelay) {
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
        web.loadHTMLString(Self.signup, baseURL: URL(string: "https://signup.example/join"))
        try await loaded.wait()
        return (web, WebFormPage(web: web, relay: relay), relay)
    }

    private func sent(_ relay: FieldRelay, by web: WKWebView, form: String) async throws -> (fields: [FormField], values: [String: String])? {
        var heard: (fields: [FormField], values: [String: String])?
        relay.onEvent = { event in
            if case .answered(let fields, let values) = event { heard = (fields, values) }
        }
        _ = try await web.evaluateJavaScript("document.getElementById('\(form)').requestSubmit(); true")
        for _ in 0..<40 where heard == nil { try await Task.sleep(for: .milliseconds(25)) }
        return heard
    }

    @Test func aSubmittedFormSendsOnlyTheBoxesThatMayBeRemembered() async throws {
        let (web, _, relay) = try await page()

        let heard = try await sent(relay, by: web, form: "join")

        let names = Set(heard?.fields.map(\.name) ?? [])
        #expect(names == ["project", "email", "team"])
        #expect(Set(heard?.values.values.map { $0 } ?? []) == ["APX-7", "ada@example.com", "b"])
    }

    @Test func aFormMarkedAutocompleteOffSendsNothing() async throws {
        let (web, _, relay) = try await page()

        let heard = try await sent(relay, by: web, form: "quiet")

        #expect(heard == nil)
    }

    @Test func theAnswersCountAsSentOnlyOnceTheirBoxesHaveGone() async throws {
        let (web, page, relay) = try await page()
        _ = try await sent(relay, by: web, form: "join")

        let before = await page.answeredStill()
        _ = try await web.evaluateJavaScript("document.getElementById('join').remove(); true")
        let after = await page.answeredStill()

        #expect(before)
        #expect(!after)
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
