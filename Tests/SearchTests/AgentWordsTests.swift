import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentWordsTests {
    private let task = UUID()

    private var browser: Browser!
    private var box: BrowserToolbox!
    private var server: LocalPageServer!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        let mine = Tab(configuration: Web.configuration(space: browser.spaceID))
        mine.restore(url: URL(string: "https://example.com/mine")!, title: "Mine")
        browser.showRow([mine], active: mine.id)
        box = BrowserToolbox()
        box.browser = browser
        browser.prefs.agentMode = .auto
        AgentSites.shared.reset()
    }

    private func tearDown() async {
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        server?.stop()
        browser.prefs.agentMode = .auto
        AgentSites.shared.reset()
        browser?.closeAll()
        browser = nil
    }

    private func page(_ body: String, more: [String: LocalPageServer.Page] = [:]) async throws -> (tab: Tab, id: String) {
        var pages = more
        pages["/page"] = .init(type: "text/html", body: "<!doctype html><title>Shop</title>" + body)
        server = try LocalPageServer(pages)
        let before = Set(browser.tabs.map(\.id))
        _ = await box.call("open", ["url": "http://127.0.0.1:\(server.port)/page"], task: task)
        let tab = try #require(browser.tabs.first { !before.contains($0.id) })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id], task: task)
        return (tab, id)
    }

    private func ref(_ tab: String, _ label: String) async throws -> String {
        let shot = await box.call("snapshot", ["tab": tab], task: task)
        let line = try #require(shot.text?.split(separator: "\n").first { $0.contains("\"\(label)\"") && $0.contains("@e") })
        let word = try #require(line.split(separator: " ").first { $0.hasPrefix("@e") })
        return String(word)
    }

    private func question() async -> AgentQuestion? {
        for _ in 0..<400 {
            if let front = AgentDesk.shared.front { return front }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    private func clicks(_ tab: Tab) async -> Int {
        (try? await tab.web.evaluateJavaScript("window.clicks || 0")) as? Int ?? 0
    }

    private func written(_ said: ToolOutcome) -> String {
        let data = said.data.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return (said.text ?? "") + "\n" + data
    }

    @Test func aWordTargetOnPayNowAsksLikeARef() async throws {
        let (tab, id) = try await page("<button onclick='window.clicks=(window.clicks||0)+1'>Pay now</button>")

        let call = Task { await box.call("click", ["tab": id, "ref": "Pay now"], task: task) }
        let asked = await question()
        let before = await clicks(tab)
        AgentDesk.shared.take(try #require(asked).id, .no)
        let done = await call.value

        #expect(asked?.kind == .approval(.pay))
        #expect(before == 0)
        #expect(done.failed)
        #expect(done.code == "said_no")
        let after = await clicks(tab)
        #expect(after == 0)
    }

    @Test func aNestedTargetAsksAndThenClicksOnYes() async throws {
        let (tab, id) = try await page("<button onclick='window.clicks=(window.clicks||0)+1'>Send message</button>")

        let call = Task { await box.call("click", ["tab": id, "target": ["words": "send message", "role": "button"]], task: task) }
        let asked = await question()
        AgentDesk.shared.take(try #require(asked).id, .yes)
        let done = await call.value

        #expect(asked?.kind == .approval(.send))
        #expect(!done.failed)
        #expect(done.data?["did"] as? String == "click")
        #expect(await clicks(tab) == 1)
    }

    @Test func wordsThatFitTwoElementsAskWhichOne() async throws {
        let (tab, id) = try await page("<button onclick='window.clicks=1'>Add</button><button onclick='window.clicks=2'>Add</button>")

        let done = await box.call("click", ["tab": id, "ref": "Add"], task: task)
        let second = await box.call("click", ["tab": id, "words": "Add", "nth": 2], task: task)

        #expect(done.failed)
        #expect(done.code == "ambiguous")
        #expect((done.data?["candidates"] as? [Any])?.count == 2)
        #expect(!second.failed)
        #expect(await clicks(tab) == 2)
    }

    @Test func wordsThatFitNothingSayWhereToLook() async throws {
        let (_, id) = try await page("<button>Keep</button>")

        let done = await box.call("click", ["tab": id, "ref": "Checkout"], task: task)

        #expect(done.failed)
        #expect(done.code == "not_found")
        #expect(done.hint?.contains("broadway snapshot") == true)
    }

    @Test func aRefWhoseWordsChangedIsRefusedOnceThenActsAsItIsNow() async throws {
        let (tab, id) = try await page("<button id=b onclick='window.clicks=(window.clicks||0)+1'>Keep</button>")
        let ref = try await ref(id, "Keep")
        _ = try await tab.web.evaluateJavaScript("document.getElementById('b').textContent = 'Keep this one'; true")

        let first = await box.call("click", ["tab": id, "ref": ref], task: task)
        let between = await clicks(tab)
        let again = await box.call("click", ["tab": id, "ref": ref], task: task)

        #expect(first.failed)
        #expect(first.code == "ref_changed")
        #expect(first.text?.contains("Keep this one") == true)
        #expect(between == 0)
        #expect(!again.failed)
        #expect(await clicks(tab) == 1)
    }

    @Test func aRefThatTurnedIntoDeleteStillAsksTheSecondTime() async throws {
        let (tab, id) = try await page("<button id=b onclick='window.clicks=(window.clicks||0)+1'>Keep</button>")
        let ref = try await ref(id, "Keep")
        _ = try await tab.web.evaluateJavaScript("document.getElementById('b').textContent = 'Delete everything'; true")

        let first = await box.call("click", ["tab": id, "ref": ref], task: task)
        let call = Task { await box.call("click", ["tab": id, "ref": ref], task: task) }
        let asked = await question()
        AgentDesk.shared.take(try #require(asked).id, .no)
        let again = await call.value

        #expect(first.code == "ref_changed")
        #expect(asked?.kind == .approval(.delete))
        #expect(again.failed)
        #expect(await clicks(tab) == 0)
    }

    @Test func aLateYesToAHeavyActPassesOnceAndOnlyForThatAct() {
        let session = UUID()
        let start = Date()

        AgentLinks.shared.giveActPass(session, .pay, site: "shop.example", quote: "Pay now", at: start)
        let other = AgentLinks.shared.takeActPass(session, .pay, site: "shop.example", quote: "Pay later", at: start)
        let first = AgentLinks.shared.takeActPass(session, .pay, site: "shop.example", quote: "Pay now", at: start.addingTimeInterval(5))
        let second = AgentLinks.shared.takeActPass(session, .pay, site: "shop.example", quote: "Pay now", at: start.addingTimeInterval(6))
        AgentLinks.shared.giveActPass(session, .send, site: "shop.example", quote: "Send", at: start)
        let late = AgentLinks.shared.takeActPass(session, .send, site: "shop.example", quote: "Send", at: start.addingTimeInterval(121))

        #expect(!other)
        #expect(first)
        #expect(!second)
        #expect(!late)
    }

    @Test func theChangeAnswerNeverCarriesAPasswordOrCardValue() async throws {
        let (_, id) = try await page("""
        <input type=password id=p aria-label=Password>
        <input id=c autocomplete=cc-number aria-label='Card number'>
        <button onclick="document.getElementById('p').value='Sup3rSecretWord'; document.getElementById('c').value='4111 1111 1111 1111'; document.getElementById('o').textContent='Saved'">Apply</button>
        <p id=o></p>
        """)

        let call = Task { await box.call("click", ["tab": id, "ref": "Apply"], task: task) }
        if let asked = await question() { AgentDesk.shared.take(asked.id, .yes) }
        let done = await call.value
        let all = written(done)

        #expect(!done.failed)
        #expect(all.contains("Saved"))
        #expect(!all.contains("Sup3rSecretWord"))
        #expect(!all.contains("4111"))
    }

    @Test func showingAPasswordKeepsItsValueOutOfTheAnswer() async throws {
        let (_, id) = try await page("""
        <input type=password id=p aria-label=Password value='Sup3rSecretWord'>
        <button onclick="document.getElementById('p').type='text'">Show password</button>
        """)
        _ = await box.call("snapshot", ["tab": id], task: task)

        let done = await box.call("click", ["tab": id, "ref": "Show password"], task: task)
        let shot = await box.call("snapshot", ["tab": id], task: task)

        #expect(!written(done).contains("Sup3rSecretWord"))
        #expect(!written(shot).contains("Sup3rSecretWord"))
    }

    @Test func enterOnASendButtonAsksEveryPress() async throws {
        let (tab, id) = try await page("<input aria-label=Note><button onclick='window.clicks=(window.clicks||0)+1'>Send message</button>")

        let call = Task { await box.call("press", ["tab": id, "key": "Enter", "ref": "Send message"], task: task) }
        let asked = await question()
        AgentDesk.shared.take(try #require(asked).id, .no)
        let done = await call.value

        #expect(asked?.kind == .approval(.send))
        #expect(done.failed)
        #expect(await clicks(tab) == 0)
    }

    @Test func theAnswerWaitsForWhatAppearsAfterAClick() async throws {
        let (_, id) = try await page("<button onclick=\"setTimeout(function(){var p=document.createElement('p');p.setAttribute('role','status');p.textContent='Added to basket';document.body.appendChild(p)},400)\">Add</button>")

        let done = await box.call("click", ["tab": id, "ref": "Add"], task: task)

        #expect(!done.failed)
        #expect(done.data?["settled"] as? String == "quiet")
        #expect((done.data?["ms"] as? Int ?? 0) >= 400)
        #expect(done.text?.contains("Added to basket") == true)
    }

    @Test func aPageDialogEndsTheWaitAtOnce() async throws {
        let (_, id) = try await page("<button onclick=\"confirm('Keep the hat?')\">Open</button>")
        let started = Date()

        let done = await box.call("click", ["tab": id, "ref": "Open"], task: task)
        let answered = await box.call("dialog", ["tab": id, "action": "dismiss"], task: task)

        #expect(done.data?["settled"] as? String == "dialog")
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(!answered.failed)
    }

    @Test func aBusyPageIsCappedAtTheSettleAsked() async throws {
        let (_, id) = try await page("<p id=t>0</p><button onclick=\"setInterval(function(){var t=document.getElementById('t');t.textContent=String(+t.textContent+1)},100)\">Start</button>")

        let done = await box.call("click", ["tab": id, "ref": "Start", "settle": 1], task: task)

        #expect(!done.failed)
        #expect(done.data?["settled"] as? String == "capped")
        #expect((done.data?["ms"] as? Int ?? 0) < 2500)
    }

    @Test func refsStartAtOneOnEachPageAndStayTheSame() async throws {
        let (_, id) = try await page("<a href='/two'>Next</a><button>Keep</button>",
                                     more: ["/two": .init(type: "text/html", body: "<!doctype html><title>Two</title><button>Back</button>")])

        let first = await box.call("snapshot", ["tab": id], task: task)
        let again = await box.call("snapshot", ["tab": id], task: task)
        let went = await box.call("click", ["tab": id, "ref": "Next"], task: task)
        let other = await box.call("snapshot", ["tab": id], task: task)

        #expect(first.text?.contains("@e1 ") == true)
        #expect(written(first).contains("\"Keep\""))
        #expect((first.data?["elements"] as? [[String: Any]])?.map { $0["ref"] as? String ?? "" } == (again.data?["elements"] as? [[String: Any]])?.map { $0["ref"] as? String ?? "" })
        #expect(went.data?["settled"] as? String == "navigated")
        #expect(other.text?.contains("@e1 button \"Back\"") == true)
    }

    @Test func aRefFromAnEarlierPageSaysWhereItWas() async throws {
        let (_, id) = try await page("<a href='/two'>Next</a><button>Keep</button><button>More</button>",
                                     more: ["/two": .init(type: "text/html", body: "<!doctype html><title>Two</title><button>Back</button>")])
        let more = try await ref(id, "More")
        _ = await box.call("click", ["tab": id, "ref": "Next"], task: task)

        let done = await box.call("click", ["tab": id, "ref": more], task: task)

        #expect(done.failed)
        #expect(done.code == "stale_ref")
        #expect(done.text?.contains("was on Shop") == true)
    }

    @Test func aLongPageShowsAHundredAndTwentyAndSaysHowManyMore() async throws {
        let buttons = (1...200).map { "<button>Item \($0)</button>" }.joined()
        let (_, id) = try await page("<main>" + buttons + "</main>")

        let shot = await box.call("snapshot", ["tab": id], task: task)
        let found = await box.call("snapshot", ["tab": id, "find": "Item 199"], task: task)
        let roles = await box.call("snapshot", ["tab": id, "role": "link"], task: task)

        #expect(shot.data?["shown"] as? Int == 120)
        #expect(shot.data?["total"] as? Int == 200)
        #expect(shot.text?.contains("… 80 more") == true)
        #expect(found.text?.contains("\"Item 199\"") == true)
        #expect(found.data?["shown"] as? Int == 1)
        #expect((roles.data?["elements"] as? [Any])?.isEmpty == true)
    }

    @Test func aBlockingDialogIsShownAlone() async throws {
        let (_, id) = try await page("""
        <button>Behind</button>
        <dialog id=d><h2>Cookies</h2><button>Accept all</button></dialog>
        <script>document.getElementById('d').showModal()</script>
        """)

        let shot = await box.call("snapshot", ["tab": id], task: task)
        let all = await box.call("snapshot", ["tab": id, "all": true], task: task)

        #expect(shot.text?.contains("Accept all") == true)
        #expect(shot.text?.contains("Behind") == false)
        #expect(shot.text?.contains("A dialog is open") == true)
        #expect(all.text?.contains("Behind") == true)
    }

    @Test func aCoveredTargetNamesWhatCoversIt() async throws {
        let (_, id) = try await page("""
        <button onclick='window.clicks=1' style='position:absolute;top:100px;left:100px'>Buy</button>
        <div role=dialog aria-label='Newsletter' style='position:fixed;inset:0;background:white'><button>Close</button></div>
        """)

        let done = await box.call("click", ["tab": id, "ref": "Buy"], task: task)

        #expect(done.failed)
        #expect(done.code == "not_actionable")
        #expect(done.text?.contains("Newsletter") == true)
        #expect(done.hint?.contains("broadway click @e") == true)
    }

    @Test func theOldFormsStillWork() async throws {
        let (tab, id) = try await page("<button onclick='window.clicks=(window.clicks||0)+1'>Keep</button><select aria-label=Size><option value=s>Small</option><option value=l>Large</option></select>")
        let keep = try await ref(id, "Keep")
        let size = try await ref(id, "Size")

        let bare = await box.call("click", ["tab": id, "ref": String(keep.dropFirst())], task: task)
        let chose = await box.call("choose", ["tab": id, "ref": size, "value": "l"], task: task)
        let byLabel = await box.call("choose", ["tab": id, "ref": size, "value": "Small"], task: task)
        let scrolled = await box.call("scroll", ["tab": id, "by": 300.0], task: task)
        let located = await box.call("locate", ["tab": id, "text": "Keep"], task: task)

        #expect(!bare.failed)
        #expect(await clicks(tab) == 1)
        #expect(!chose.failed)
        #expect(!byLabel.failed)
        let value = try await tab.web.evaluateJavaScript("document.querySelector('select').value") as? String
        #expect(value == "s")
        #expect(!scrolled.failed)
        #expect(located.text?.contains("\"Keep\"") == true)
    }

    @Test func aDialogIsAnsweredWithoutItsId() async throws {
        let (tab, id) = try await page("<button onclick=\"window.said=confirm('Leave?')\">Go</button>")
        _ = await box.call("click", ["tab": id, "ref": "Go"], task: task)

        let read = await box.call("dialog", ["tab": id], task: task)
        let done = await box.call("dialog", ["tab": id, "action": "accept"], task: task)

        #expect(read.text?.contains("Leave?") == true)
        #expect(read.text?.contains("id ") == true)
        #expect(!done.failed)
        let said = try await tab.web.evaluateJavaScript("window.said === true") as? Bool
        #expect(said == true)
    }

    @Test func waitFindsWordsInAnyCaseAndSaysWhatIsThereWhenItTimesOut() async throws {
        let (_, id) = try await page("<h1>Your basket</h1><input aria-label=Coupon value='SPRING DEAL'>")

        let there = await box.call("wait", ["tab": id, "text": "your BASKET"], task: task)
        let field = await box.call("wait", ["tab": id, "text": "spring deal"], task: task)
        let missing = await box.call("wait", ["tab": id, "text": "Order placed", "seconds": 1.0], task: task)

        #expect(!there.failed)
        #expect(!field.failed)
        #expect(missing.failed)
        #expect(missing.code == "timeout")
        #expect(missing.text?.contains("Your basket") == true)
    }

    @Test func aSignInButtonAsksToSignInAndSignAndSendStillSends() async throws {
        let (tab, id) = try await page("<button onclick='window.clicks=(window.clicks||0)+1'>Sign in</button><button onclick='window.clicks=(window.clicks||0)+1'>Sign and send</button>")

        let call = Task { await box.call("click", ["tab": id, "ref": "Sign in"], task: task) }
        let asked = await question()
        AgentDesk.shared.take(try #require(asked).id, .no)
        _ = await call.value
        let sending = Task { await box.call("click", ["tab": id, "ref": "Sign and send"], task: task) }
        let second = await question()
        AgentDesk.shared.take(try #require(second).id, .no)
        _ = await sending.value

        #expect(asked?.title == "Sign in on 127.0.0.1?")
        #expect(second?.title == "Send on 127.0.0.1?")
        #expect(await clicks(tab) == 0)
    }

    @Test func seedPhrasesAndPrivateKeysAreSecretFields() async throws {
        let (_, id) = try await page("""
        <label>Recovery phrase <input id=seed></label>
        <fieldset><legend>Your seed words</legend><input aria-label='Word 1'></fieldset>
        <textarea aria-label='Notes'>-----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAA
        -----END OPENSSH PRIVATE KEY-----</textarea>
        """)

        let seed = await box.call("type", ["tab": id, "label": "Recovery phrase", "text": "apple"], task: task)
        let word = await box.call("type", ["tab": id, "ref": "Word 1", "text": "apple"], task: task)
        let shot = await box.call("snapshot", ["tab": id], task: task)

        #expect(seed.code == "secret_field")
        #expect(word.code == "secret_field")
        #expect(!written(shot).contains("b3BlbnNzaC1rZXktdjEAAAAA"))
    }

    @Test func theSameStepAfterANoIsRefusedWithoutAskingAgain() async throws {
        let (tab, id) = try await page("<button onclick='window.clicks=(window.clicks||0)+1'>Pay now</button>")

        let call = Task { await box.call("click", ["tab": id, "ref": "Pay now"], task: task) }
        let asked = await question()
        AgentDesk.shared.take(try #require(asked).id, .no)
        _ = await call.value
        let again = await box.call("click", ["tab": id, "ref": "Pay now"], task: task)

        #expect(again.code == "said_no")
        #expect(AgentDesk.shared.pending.isEmpty)
        #expect(await clicks(tab) == 0)
    }

    @Test func aSnapshotSaysWhichFieldIsWrongAndWhy() async throws {
        let (_, id) = try await page("<input aria-label=Email aria-invalid=true aria-describedby=err value=nope><p id=err>Enter a valid email</p>")

        let shot = await box.call("snapshot", ["tab": id], task: task)

        #expect(shot.text?.contains("invalid=\"Enter a valid email\"") == true)
    }

    @Test func aSignInPageSaysItNeedsAPasswordAndACodePageACode() async throws {
        let (_, id) = try await page("<input aria-label=Email><input type=password aria-label=Password><button>Sign in</button>")
        let shot = await box.call("snapshot", ["tab": id], task: task)
        server.stop()
        let (_, other) = try await page("<input autocomplete=one-time-code aria-label=Code><button>Verify</button>")
        let code = await box.call("snapshot", ["tab": other], task: task)

        #expect(shot.data?["needs"] as? String == "password")
        #expect(shot.text?.contains("needs: a password, so run broadway fill login") == true)
        #expect((shot.data?["lines"] as? [String])?.contains { $0.hasPrefix("needs:") } == false)
        #expect(code.data?["needs"] as? String == "code")
    }

    @Test func aPlainAlertIsAcceptedAndReported() async throws {
        let (tab, id) = try await page("<button onclick=\"alert('Saved'); window.after=true\">Keep</button>")

        let done = await box.call("click", ["tab": id, "ref": "Keep"], task: task)

        #expect(!done.failed)
        #expect(done.text?.contains("The page showed an alert: \"Saved\". Broadway closed it") == true)
        #expect((done.data?["dialog"] as? [String: Any])?["accepted"] as? Bool == true)
        #expect(tab.agentDialog == nil)
        let after = try await tab.web.evaluateJavaScript("window.after === true") as? Bool
        #expect(after == true)
    }

    @Test func aFieldThatChangesWhatWasTypedSaysSo() async throws {
        let (_, id) = try await page("<input aria-label=Phone oninput=\"this.value=this.value.replace(/[^0-9]/g,'')\">")

        let done = await box.call("type", ["tab": id, "label": "Phone", "text": "555-0100", "replace": true], task: task)

        #expect(done.text?.contains("(the field made it \"5550100\")") == true)
    }

    @Test func aScrollableBoxAndAHoverMenuAreNamed() async throws {
        let (_, id) = try await page("""
        <style>.menu .sub{display:none}.menu:hover .sub{display:block}</style>
        <div class=menu><a href='#'>Teas</a><div class=sub><a href='#'>Green</a></div></div>
        <div aria-label=Messages style='height:60px;width:200px;overflow:auto'><p>One</p><p>Two</p><p>Three</p><p>Four</p><p>Five</p></div>
        """)

        let shot = await box.call("snapshot", ["tab": id], task: task)

        #expect(shot.text?.contains("link \"Teas\" -> / opens-on-hover") == true || shot.text?.contains("opens-on-hover") == true)
        #expect(shot.text?.contains("scrollable \"Messages\" scrolls") == true)
    }

    @Test func theFirstLookAtASiteWithNotesSaysSoOnce() async throws {
        let notes = try #require(Skill.parse("# Local tea\nsites: 127.0.0.1\n\nThe basket is at the top."))
        box.siteNotes = { url in notes.serves(url) ? [notes] : [] }
        let (_, id) = try await page("<button>Tea</button>")

        let first = await box.call("snapshot", ["tab": id], task: task)
        let second = await box.call("snapshot", ["tab": id], task: task)

        #expect(first.text?.contains("note: Broadway has notes for this site: broadway skill local-tea") == true)
        #expect(first.data?["skill"] as? String == "local-tea")
        #expect(second.text?.contains("note: Broadway has notes") == false)
        #expect(second.data?["skill"] == nil)
    }

    @Test func aRepeatWhileTheQuestionIsOpenJoinsItInsteadOfAskingAgain() async throws {
        let (tab, id) = try await page("<button onclick='window.clicks=(window.clicks||0)+1'>Pay now</button>")
        let mine = UUID()
        TaskLedger.shared.open(mine, title: "An agent")
        AgentLinks.shared.setPatience(mine, 0.3)
        defer { AgentLinks.shared.setPatience(mine, nil) }

        let first = await box.call("click", ["tab": id, "ref": "Pay now"], task: mine)
        let asked = AgentDesk.shared.pending.count
        let second = await box.call("click", ["tab": id, "ref": "Pay now"], task: mine)
        let still = AgentDesk.shared.pending.count
        let third = Task { await box.call("click", ["tab": id, "ref": "Pay now"], task: mine) }
        try? await Task.sleep(for: .milliseconds(100))
        AgentDesk.shared.take(try #require(AgentDesk.shared.front).id, .yes)
        let done = await third.value

        #expect(first.code == "needs_you")
        #expect(second.code == "needs_you")
        #expect(asked == 1)
        #expect(still == 1)
        #expect(!done.failed)
        #expect(await clicks(tab) == 1)
        #expect(AgentDesk.shared.pending.isEmpty)
    }

    @Test func aSignInFormNamesTheProvidersThisSpaceIsSignedInTo() async throws {
        let (tab, id) = try await page("""
        <form><input type=email aria-label=Email><input type=password aria-label=Password><button>Sign in</button>
        <button type=button>Continue with Google</button><button type=button>Continue with GitHub</button></form>
        <footer><a href='#'>Apple</a></footer>
        """)
        let jar = tab.web.configuration.websiteDataStore.httpCookieStore
        let cookie = try #require(HTTPCookie(properties: [.domain: ".google.com", .path: "/", .name: "SID", .value: "made-up", .secure: true]))
        await jar.setCookie(cookie)

        let shot = await box.call("snapshot", ["tab": id], task: task)
        await jar.deleteCookie(cookie)
        let after = await box.call("snapshot", ["tab": id], task: task)

        #expect(shot.text?.contains("signs in with: Google (this space is signed in to it)") == true)
        #expect(shot.data?["ways"] as? [String] == ["Google"])
        #expect(shot.data?["needs"] as? String == "password")
        #expect(after.data?["ways"] == nil)
    }

    @Test func aTokenBoxOutsideASignInSendsNoOneToFillLogin() async throws {
        let (_, token) = try await page("<form><label>API token <input type=password name=token autocomplete=off></label><button>Save</button></form>")
        let shot = await box.call("snapshot", ["tab": token], task: task)
        server.stop()
        let (_, signIn) = try await page("<form><input aria-label=Email><label>Secret key <input type=password name=key></label><button>Sign in</button></form>")
        let other = await box.call("snapshot", ["tab": signIn], task: task)

        #expect(shot.data?["needs"] == nil)
        #expect(shot.text?.contains("fill login") == false)
        #expect(other.data?["needs"] as? String == "password")
    }

    @Test func aClosedShadowRootIsNotedOnceAndAMissNamesWhatWorksThere() async throws {
        let (_, id) = try await page("""
        <style>i.icon::before{content:"";display:inline-block;width:16px;height:16px}</style>
        <h1>Widget</h1><div id="spacer" style="height:40px"></div><i class="icon"></i><div style="aspect-ratio:2;width:80px"></div>
        <table><tr><td>Name</td><td></td></tr></table><div style="position:relative;height:60px"><div style="position:absolute;inset:0"></div></div>
        <div id="closed"><span>light words</span></div>
        <script>
        var c = document.getElementById('closed').attachShadow({mode: 'closed'});
        c.innerHTML = '<button type="button">Hidden action</button><p>Inside the closed root</p>';
        </script>
        """)

        let shot = await box.call("snapshot", ["tab": id], task: task)
        let missed = await box.call("click", ["tab": id, "target": ["words": "Hidden action"]], task: task)
        let noted = (shot.plain ?? shot.text ?? "").split(separator: "\n").filter { $0.contains("closed to reading") }
        let said = "\(missed.text ?? "") \(missed.hint ?? "") \(missed.data ?? [:])"

        #expect(noted.count == 1)
        #expect(noted.first?.trimmingCharacters(in: .whitespaces).hasPrefix("@") == true)
        #expect(shot.text?.contains("Hidden action") == false)
        #expect(missed.failed)
        #expect(said.contains("closed to reading"))
        #expect(said.contains("broadway click --at X,Y"))
    }

    @Test func rowsSortedByAClickAreToldAsANewOrder() async throws {
        let rows = (0..<12).map { "<tr><td>L-\(100 + $0)</td><td>\(($0 * 37) % 90 + 10)</td></tr>" }.joined()
        let (_, id) = try await page("<h1>Ledger</h1><table><thead><tr><th><button type=button onclick='sortBy()'>Sort by amount</button></th></tr></thead><tbody>\(rows)</tbody></table><script>function sortBy(){var b=document.querySelector('tbody');var r=[].slice.call(b.rows);r.sort(function(x,y){return parseFloat(y.cells[1].textContent)-parseFloat(x.cells[1].textContent)});r.forEach(function(x){b.appendChild(x)})}</script>")

        let said = await box.call("click", ["tab": id, "ref": "Sort by amount"], task: task)

        #expect(said.text?.contains("~ the rows of \"Ledger\" are in a new order") == true, "\(said.text ?? "") \(said.data ?? [:])")
    }

    @Test func aRegionThatScrollsIsATargetForScroll() async throws {
        let (_, id) = try await page("<div role=region aria-label=Strip style='width:240px;overflow-x:auto;white-space:nowrap'><span style='display:inline-block;width:2400px'>Start of a long line</span></div>")

        let shot = await box.call("snapshot", ["tab": id], task: task)
        let moved = await box.call("scroll", ["tab": id, "target": ["words": "Strip"], "by": "right"], task: task)

        #expect(shot.text?.contains("scrollable \"Strip\" scrolls") == true, "\(shot.text ?? "")")
        #expect(!moved.failed, "\(moved.text ?? "") \(moved.hint ?? "")")
        #expect(moved.text?.contains("more to the right") == true, "\(moved.text ?? "")")
    }

    @Test func twoPasswordFieldsAreASettingsPageNotASignIn() async throws {
        let (_, id) = try await page("<input type=password aria-label=Old><input type=password aria-label=New autocomplete=new-password><input type=password aria-label=Again>")

        let shot = await box.call("snapshot", ["tab": id], task: task)

        #expect(shot.data?["needs"] == nil)
    }

    @Test func aClickAtAPointFindsTheElementThereAndAsksLikeARef() async throws {
        let (tab, id) = try await page("""
        <button style='position:fixed;left:40px;top:40px;width:120px;height:40px' onclick='window.clicks=(window.clicks||0)+1'>Keep</button>
        <button style='position:fixed;left:40px;top:120px;width:120px;height:40px' onclick='window.clicks=(window.clicks||0)+10'>Pay now</button>
        """)

        let kept = await box.call("click", ["tab": id, "target": ["at": ["x": 100, "y": 60]]], task: task)
        let call = Task { await box.call("click", ["tab": id, "target": ["at": ["x": 100, "y": 140]]], task: task) }
        let asked = await question()
        AgentDesk.shared.take(try #require(asked).id, .no)
        let paid = await call.value
        let empty = await box.call("click", ["tab": id, "target": ["at": ["x": 5000, "y": 5000]]], task: task)

        #expect(!kept.failed)
        #expect(kept.text?.contains("\"Keep\"") == true)
        #expect(asked?.kind == .approval(.pay))
        #expect(paid.code == "said_no")
        #expect(empty.failed)
        #expect(await clicks(tab) == 1)
    }

    @Test func givingAccessIsHeavyAndABareAllowIsNot() {
        #expect(ActionKind.of(ActionFacts(["name": "Authorize", "tag": "button"])) == .act(.grant))
        #expect(ActionKind.of(ActionFacts(["name": "Allow access", "tag": "a"])) == .act(.grant))
        #expect(ActionKind.of(ActionFacts(["name": "Allow", "tag": "a"])) == .plain)
        #expect(ActionKind.of(ActionFacts(["name": "Continue", "tag": "button", "type": "submit", "formMethod": "post",
                                           "page": "https://accounts.example/oauth/authorize?client_id=made-up&scope=mail"])) == .act(.grant))
        #expect(ActionKind.of(ActionFacts(["name": "Continue", "tag": "button", "type": "submit", "formMethod": "post",
                                           "page": "https://accounts.example/oauth/authorize"])) == .act(.send))
        #expect(AgentAct.grant.heavy)
        #expect(AgentPolicy.verdict(.grant, mode: .auto, rule: .always) == .ask)
        #expect(!AgentPolicy.offersAlways(.grant))
    }

    @Test func aYesToGiveAccessDoesNotHoldForTheNextOne() async throws {
        let (tab, id) = try await page("<button onclick='window.clicks=(window.clicks||0)+1'>Authorize</button>")

        let call = Task { await box.call("click", ["tab": id, "ref": "Authorize"], task: task) }
        let asked = await question()
        AgentDesk.shared.take(try #require(asked).id, .yes)
        let first = await call.value
        let again = Task { await box.call("click", ["tab": id, "ref": "Authorize"], task: task) }
        let second = await question()
        AgentDesk.shared.take(try #require(second).id, .no)
        _ = await again.value

        #expect(asked?.kind == .approval(.grant))
        #expect(asked?.title.hasPrefix("Give access to your account on") == true)
        #expect(!first.failed)
        #expect(second != nil)
        #expect(await clicks(tab) == 1)
    }

    @Test func anOldRefAfterAReloadOfTheSameAddressIsStaleAndTheLooksRefWorks() async throws {
        let (tab, id) = try await page("<button onclick='window.clicks=(window.clicks||0)+1'>Keep</button><button onclick='window.clicks=(window.clicks||0)+10'>Other</button>")
        let old = try await ref(id, "Other")
        let before = tab.web.url
        _ = try await tab.web.evaluateJavaScript("location.reload(); true")
        try? await Task.sleep(for: .milliseconds(600))
        _ = await box.call("wait", ["tab": id], task: task)

        let stale = await box.call("click", ["tab": id, "ref": old], task: task)
        let reloaded = await box.call("navigate", ["tab": id, "url": "http://127.0.0.1:\(server.port)/page"], task: task)
        let look = reloaded.data?["look"] as? [String: Any]
        let fresh = try #require((look?["elements"] as? [[String: Any]])?.first { $0["name"] as? String == "Keep" }?["ref"] as? String)
        let kept = await box.call("click", ["tab": id, "ref": fresh], task: task)

        #expect(tab.web.url == before)
        #expect(stale.code == "stale_ref")
        #expect(!kept.failed)
        #expect(await clicks(tab) == 1)
    }

    @Test func aRefCarriedOnlyToAnotherSessionIsStaleAfterAReload() async throws {
        let (tab, id) = try await page("<button onclick='window.clicks=(window.clicks||0)+1'>Keep</button>")
        let mine = try await ref(id, "Keep")
        _ = try await tab.web.evaluateJavaScript("location.reload(); true")
        try? await Task.sleep(for: .milliseconds(600))
        let other = UUID()
        _ = await box.call("snapshot", ["tab": id], task: other)

        let guessed = await box.call("click", ["tab": id, "ref": mine], task: task)
        let theirs = await box.call("click", ["tab": id, "ref": mine], task: other)

        #expect(guessed.code == "stale_ref")
        #expect(!theirs.failed)
        #expect(await clicks(tab) == 1)
    }

    @Test func aSecretBoxInACardFormNeverPutsItsValueInThePersonsQuestion() async throws {
        let (_, id) = try await page("""
        <form><input id=pass type=password value=made-up-secret-7><input autocomplete=cc-number value=4242424242424242>
        <button type=button>Inside</button></form>
        """)
        let shot = await box.call("snapshot", ["tab": id], task: task)
        let elements = shot.data?["elements"] as? [[String: Any]] ?? []
        let secret = try #require(elements.first { ($0["name"] as? String) == "password field" }?["ref"] as? String)

        let call = Task { await box.call("click", ["tab": id, "ref": secret], task: task) }
        let asked = await question()
        let quotes = AgentDesk.shared.pending.map(\.quote)
        if let asked { AgentDesk.shared.take(asked.id, .no) }
        _ = await call.value

        #expect(elements.filter { ($0["name"] as? String) == "Inside" }.map { $0["role"] as? String } == ["button"])
        #expect(asked != nil)
        #expect(asked?.quote.contains("made-up-secret") == false)
        #expect(asked?.quote.contains("4242") == false)
        #expect(quotes.allSatisfy { !$0.contains("made-up-secret") })
    }

    @Test func anAnswerWithoutItsLookTellsNoRefs() async throws {
        let (tab, id) = try await page("<button onclick='window.clicks=(window.clicks||0)+1'>Keep</button><button onclick='window.clicks=(window.clicks||0)+10'>Other</button>")
        let old = try await ref(id, "Other")

        let went = await box.call("navigate", ["tab": id, "url": "http://127.0.0.1:\(server.port)/page", "look": false], task: task)
        let stale = await box.call("click", ["tab": id, "ref": old], task: task)

        #expect(!went.failed)
        #expect(went.data?["look"] == nil)
        #expect(stale.code == "stale_ref")
        #expect(await clicks(tab) == 0)
    }

    private func wire(_ arguments: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func numbersOneAndZeroFromTheWireAreNumbersNotFlags() throws {
        let one = try wire(["target": ["words": "Grant access", "nth": 1], "nth": 1, "settle": 1])
        let off = try wire(["settle": false, "look": true])

        #expect(AgentTarget(one).nth == 1)
        #expect(AgentSettleRule.cap(one) == 1)
        #expect(AgentSettleRule.cap(off) == nil)
        #expect(AgentTarget.flag(off["look"]))
        #expect(!AgentTarget.flag(one["nth"]))
    }

    @Test func nthOneFromTheWirePicksTheFirstRowsGrantAccess() async throws {
        let rows = [("Copperline", "stock counts", 1), ("Gullwing Freight", "shipments", 2), ("Tallyho Books", "invoices", 3)].map { name, what, n in
            "<tr><td>\(name)</td><td>Wants to see your \(what)</td><td><button type='button' onclick='window.clicks=\(n)'>Grant access</button></td></tr>"
        }.joined()
        let (tab, id) = try await page("<h1>Connections</h1><table><tr><th>App</th><th>Asks for</th><th></th></tr>\(rows)</table>")
        let arguments = try wire(["tab": id, "target": ["words": "Grant access", "nth": 1], "nth": 1])

        let call = Task { await box.call("click", arguments, task: task) }
        let asked = await question()
        AgentDesk.shared.take(try #require(asked).id, .yes)
        let done = await call.value

        #expect(asked?.kind == .approval(.grant))
        #expect(done.code != "ambiguous")
        #expect(!done.failed)
        #expect(await clicks(tab) == 1)
    }

    @Test func typingIntoADropdownNamesChooseWithItsRef() async throws {
        let (tab, id) = try await page("<label for='who'>Assignee</label><select id='who'><option>Unassigned</option><option>Hollis Grane</option></select>")

        let typed = await box.call("type", ["tab": id, "ref": "Assignee", "text": "Hollis Grane"], task: task)
        let value = try await tab.web.evaluateJavaScript("document.getElementById('who').value") as? String

        #expect(typed.failed)
        #expect(typed.code == "not_actionable")
        #expect(typed.data?["reason"] as? String == "dropdown")
        #expect(typed.hint?.contains("broadway choose @e") == true)
        #expect(typed.hint?.contains("\"Hollis Grane\"") == true)
        #expect(value == "Unassigned")
    }

    @Test func selectOnADropdownChoosesLikeChoose() async throws {
        let (tab, id) = try await page("<label for='who'>Assignee</label><select id='who'><option>Unassigned</option><option>Hollis Grane</option></select>")

        let said = await box.call("select", ["tab": id, "ref": "Assignee", "text": "Hollis Grane"], task: task)
        let value = try await tab.web.evaluateJavaScript("document.getElementById('who').value") as? String

        #expect(!said.failed, "\(said.text ?? "")")
        #expect(said.data?["did"] as? String == "choose")
        #expect(value == "Hollis Grane")
    }

    @Test func selectOnADropdownPassesTheSameGateAsChoose() async throws {
        let (tab, id) = try await page("<select aria-label='Plan'><option value='plain'>Keep</option><option value='pay'>Buy now</option></select>")

        let call = Task { await box.call("select", ["tab": id, "ref": "Plan", "text": "Buy now"], task: task) }
        let asked = await question()
        AgentDesk.shared.take(try #require(asked).id, .no)
        let done = await call.value
        let value = try await tab.web.evaluateJavaScript("document.querySelector('select').value") as? String

        #expect(asked?.kind == .approval(.pay))
        #expect(done.code == "said_no")
        #expect(value == "plain")
    }

    @Test func readFindGivesTheShownLinesHoldingTheWords() async throws {
        let (_, id) = try await page("<p>Copperline box: Price 12.00</p><p>Delivery in two days</p><p>Gullwing price on request</p><p style='display:none'>Hidden price 1.00</p>")

        let found = await box.call("text", ["tab": id, "find": "PRICE"], task: task)
        let none = await box.call("text", ["tab": id, "find": "harrier"], task: task)
        let text = found.text ?? ""

        #expect(!found.failed)
        #expect(text.contains("2 lines with \"PRICE\""))
        #expect(text.contains("Copperline box: Price 12.00"))
        #expect(text.contains("Gullwing price on request"))
        #expect(!text.contains("Delivery"))
        #expect(!text.contains("Hidden price"))
        #expect(none.failed)
        #expect(none.code == "not_found")
        #expect(none.hint?.contains("broadway snapshot --find harrier") == true)
    }

    @Test func aShortLabelLineComesWithTheLineAfterIt() {
        let text = "Order CL-4471\nTotal\n\n609.00\nCustomer:\nHollis Grane\nThe total of every order this year is shown on the next page"

        let total = BrowserToolbox.lines(of: text, holding: "total").text ?? ""
        let customer = BrowserToolbox.lines(of: text, holding: "customer").text ?? ""

        #expect(total.contains("2 lines with \"total\""))
        #expect(total.contains("Total: 609.00"))
        #expect(total.contains("The total of every order this year is shown on the next page\n") == false)
        #expect(total.hasSuffix("The total of every order this year is shown on the next page"))
        #expect(customer.contains("1 line with \"customer\"\nCustomer: Hollis Grane"))
    }

    @Test func findWithNoMatchSaysSoAndWhereToLook() async throws {
        let (_, id) = try await page("<button>Archive</button><p>Copperline orders</p>")

        let none = await box.call("locate", ["tab": id, "text": "Bundle margin rebate"], task: task)
        let roleOnly = await box.call("locate", ["tab": id, "role": "switch"], task: task)
        let some = await box.call("locate", ["tab": id, "text": "Archive"], task: task)

        #expect(none.failed)
        #expect(none.code == "not_found")
        #expect(none.text?.contains("No element fits \"Bundle margin rebate\"") == true)
        #expect(none.hint?.contains("broadway snapshot") == true)
        #expect(roleOnly.code == "not_found")
        #expect(roleOnly.text?.contains("No switch on this page") == true)
        #expect(!some.failed)
    }

    @Test func linesHoldingWordsAreCountedAndCut() {
        let text = (1...70).map { "Row \($0) total" }.joined(separator: "\n") + "\nNothing here"

        let said = BrowserToolbox.lines(of: text, holding: "TOTAL")

        #expect(said.text?.contains("70 lines with \"TOTAL\"") == true)
        #expect(said.text?.contains("Row 60 total") == true)
        #expect(said.text?.contains("Row 61 total") == false)
        #expect(said.text?.contains("… 10 more lines") == true)
        #expect(said.text?.contains("Nothing here") == false)
    }

    @Test func selectThatPicksNothingSaysSo() async throws {
        let (_, id) = try await page("<input aria-label='Note' value=''><input aria-label='Ticket' value='Ticket T-385'>")

        let empty = await box.call("select", ["tab": id, "ref": "Note"], task: task)
        let found = await box.call("select", ["tab": id, "ref": "Ticket", "text": "T-385"], task: task)

        #expect(empty.failed)
        #expect(empty.code == "not_found")
        #expect(!found.failed)
        #expect(written(found).contains("T-385"))
    }
}
