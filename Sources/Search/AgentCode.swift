import Foundation

@MainActor
enum AgentSignInRecord {
    private static var at: [String: Date] = [:]
    private static var items: [String: OnePasswordItem] = [:]

    static func note(_ link: UUID?, site: String) {
        guard let link else { return }
        at["\(link.uuidString)|\(site)"] = Date()
    }

    static func note(_ link: UUID?, site: String, item: OnePasswordItem?) {
        guard let link else { return }
        items["\(link.uuidString)|\(site)"] = item
    }

    static func item(_ link: UUID?, site: String) -> OnePasswordItem? {
        guard let link, lately(link, site: site, within: 600) else { return nil }
        return items["\(link.uuidString)|\(site)"]
    }

    static func when(_ link: UUID?, site: String) -> Date? {
        link.flatMap { at["\($0.uuidString)|\(site)"] }
    }

    static func lately(_ link: UUID?, site: String, within: TimeInterval = 300) -> Bool {
        when(link, site: site).map { Date().timeIntervalSince($0) < within } ?? false
    }
}

@MainActor
enum AgentCodes {
    static var patience: TimeInterval = 60
    static var every: TimeInterval = 3
    static var fake: CodeSource?

    static func sources(_ browser: Browser) -> [CodeSource] {
        if let fake { return [fake] }
        guard let address = GmailAccount.feed(account: GmailAccount.index(among: browser.tabs.filter { !$0.shy }.map(\.pageAddress))) else { return [] }
        let store = Spaces.store(for: browser.spaceID)
        return [GmailCodes(feed: WebGmailFeed(address: address, store: store), signedIn: { await GmailAccount.signedIn(store) },
                           told: { [weak browser] in browser?.announce("Looking in your Gmail for a code for an agent") })]
    }
}

@MainActor
enum AgentCodeFit {
    static func fits(_ code: OneTimeCode, site: String) -> Bool {
        let address = code.address.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        if let at = address.lastIndex(of: "@") {
            let domain = String(address[address.index(after: at)...])
            if !domain.isEmpty, domain == site || domain.hasSuffix("." + site) || AgentSites.site(of: URL(string: "https://" + domain)) == site { return true }
        }
        let label = site.split(separator: ".").first.map { String($0).lowercased() } ?? ""
        guard label.count >= 3, !label.allSatisfy(\.isNumber) else { return false }
        return code.sender.lowercased().split { !$0.isLetter && !$0.isNumber }.contains { String($0) == label }
    }

    static func pick(_ codes: [OneTimeCode], site: String, since: Date) -> (code: OneTimeCode?, strangers: Int) {
        let fresh = codes.filter { $0.at > since }
        let fitting = fresh.filter { fits($0, site: site) }.sorted { $0.at > $1.at }
        return (fitting.first, fresh.count - fitting.count)
    }

    static func local(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host()?.lowercased() ?? "")
    }

    static func allowed(_ url: URL?, privateTab: Bool) -> Bool {
        guard let url, !privateTab else { return false }
        let scheme = url.scheme?.lowercased()
        return scheme == "https" || (scheme == "http" && local(url))
    }
}

enum AgentCodePage {
    static let lookScript = AgentPage.naming + """

    var words = String(document.body ? document.body.innerText : '').toLowerCase().slice(0, 6000);
    var app = /authenticator|authentication app|auth app|\\btotp\\b|code (from|in|on) your (app|device)/.test(words);
    var text = /text message|\\bsms\\b|\\btexted\\b|sent (a code |a text |it )?to your (phone|mobile)|(phone|mobile|number) ending/.test(words);
    var mail = /e-?mail|inbox|gmail|mailbox/.test(words);
    function called(b) {
      var said = [b.getAttribute('autocomplete'), b.name, b.id, b.getAttribute('aria-label'), b.getAttribute('placeholder')].join(' ');
      if (b.labels) for (var l = 0; l < b.labels.length; l++) said += ' ' + (b.labels[l].textContent || '');
      return said.toLowerCase();
    }
    var inputs = Array.prototype.filter.call(document.querySelectorAll('input'), function (b) {
      return seen(b) && !b.disabled && !b.readOnly && /^(text|tel|number|password|)$/.test((b.getAttribute('type') || '').toLowerCase());
    });
    var ones = inputs.filter(function (b) { return b.maxLength === 1; });
    var single = inputs.filter(function (b) {
      var c = called(b);
      return b.maxLength !== 1 && /one-time-code|\\botp\\b|one.?time|verification.?code|verify|security.?code|2fa|two.?factor|auth\\w* ?code|sms.?code|\\bcode\\b|\\bpin\\b/.test(c)
        && !/coupon|promo|voucher|gift|\\bzip\\b|postal|post ?code|country|discount|referral|invite|area ?code/.test(c);
    });
    var split = ones.length >= 4 && ones.length <= 8;
    var boxes = split ? ones : single.slice(0, 1);
    window.__broadwayCodeBoxes = boxes;
    return { app: app, text: text, mail: mail, boxes: boxes.length, split: split };
    """

    static let fillScript = """
    var boxes = (window.__broadwayCodeBoxes || []).filter(function (b) { return b.isConnected; });
    if (!boxes.length) return { failed: 'The code box went away', code: 'not_found' };
    var split = boxes.length > 1;
    if (split && boxes.length < code.length) return { failed: 'The page has ' + boxes.length + ' boxes, too few for the code', code: 'refused' };
    var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    function put(box, value) {
      box.focus();
      setter.call(box, value);
      box.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: value }));
      box.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, key: value.slice(-1) }));
      box.dispatchEvent(new Event('change', { bubbles: true }));
    }
    if (split) { for (var i = 0; i < code.length; i++) put(boxes[i], code.charAt(i)); } else { put(boxes[0], code); }
    return { ok: true };
    """

    static let sendScript = AgentPage.naming + """

    var boxes = (window.__broadwayCodeBoxes || []).filter(function (b) { return b.isConnected; });
    if (!boxes.length) return { sent: false, gone: true };
    var last = boxes[boxes.length - 1];
    if (last.form) {
      if (last.form.requestSubmit) last.form.requestSubmit(); else last.form.submit();
      return { sent: true };
    }
    var buttons = Array.prototype.filter.call(document.querySelectorAll('button,[role=button],input[type=submit]'), function (b) {
      return seen(b) && !b.disabled && /verify|continue|submit|confirm|sign in|log in|next|done/i.test(b.innerText || b.value || b.getAttribute('aria-label') || '');
    });
    if (!buttons.length) return { sent: false };
    buttons[0].click();
    return { sent: true };
    """
}

@MainActor
enum PersonCode {
    static func handHint(_ what: String) -> String { "Run broadway handoff \"\(what)\", or ask the person for it" }

    static func run(_ call: PersonCall) async throws -> [String: Any] {
        let tab = try call.page.tab
        guard !tab.asleep, tab.isWeb else { throw PersonRefusal("not_a_page", "That tab isn't showing a web page") }
        guard let place = tab.pageAddress, let host = place.host()?.lowercased(), !host.isEmpty else {
            throw PersonRefusal("refused", "That page has no site to fill a code for")
        }
        let site = AgentSites.site(of: place) ?? host
        if AgentSites.shared.rule(for: site) == .never {
            throw PersonRefusal("never_here", "The person never lets agents act on \(site). Leave it.")
        }
        guard AgentCodeFit.allowed(place, privateTab: tab.shy) else {
            throw PersonRefusal("refused", "Broadway fills codes only on https pages", hint: handHint("Type the code you were sent"))
        }
        guard let looked = await tab.searchValue("(function(){" + AgentCodePage.lookScript + "})()") as? [String: Any] else {
            throw PersonRefusal("no_answer", "The page gave no answer")
        }
        guard (looked["boxes"] as? Int ?? 0) > 0 else {
            throw PersonRefusal("not_found", "There's no code box on that page", hint: "broadway snapshot shows what the page asks for")
        }
        let mail = looked["mail"] as? Bool == true
        let app = looked["app"] as? Bool == true
        let text = looked["text"] as? Bool == true
        if call.browser.prefs.onePassword, app || (!text && !mail),
           let item = await onePasswordItem(call, place: place, site: site, app: app) {
            call.channel?.send(["event": "asking", "message": "Asking 1Password for the code"])
            if let first = await OnePassword.oneTimeCode(item) {
                try await askForCode(call, tab: tab, site: site, title: "Fill the code 1Password keeps for \(site)?")
                let code = await OnePassword.oneTimeCode(item) ?? first
                guard tab.pageAddress == place, !tab.driving else {
                    throw PersonRefusal("refused", "The page changed while Broadway asked 1Password, so nothing was filled. Look again.")
                }
                return try await fill(call, tab: tab, place: place, code: code)
            }
            if app {
                throw PersonRefusal("nothing_kept", "1Password gave no one-time code for this sign-in. Nothing was filled.",
                                    hint: handHint("Type the code from your authenticator app"))
            }
        }
        if app {
            throw PersonRefusal("nothing_kept", "The page asks for a code from an authenticator app, which Broadway can't read. Nothing was filled.",
                                hint: handHint("Type the code from your authenticator app"))
        }
        if looked["text"] as? Bool == true, !mail {
            throw PersonRefusal("nothing_kept", "The page sent the code by text message, which Broadway can't read. Nothing was filled.",
                                hint: handHint("Type the code you were texted"))
        }
        guard AutofillBook.shared.codesFromGmail else {
            throw PersonRefusal("nothing_kept", "Codes from Gmail is off in Broadway, so no code was looked for. Nothing was filled.",
                                hint: handHint("Type the code you were sent"))
        }
        let signedIn = AgentSignInRecord.when(call.link?.id, site: site)
        try await askForCode(call, tab: tab, site: site, title: "Fill the code Gmail received for \(site)?")
        let since = signedIn.flatMap { Date().timeIntervalSince($0) < 600 ? $0.addingTimeInterval(-10) : nil } ?? Date().addingTimeInterval(-120)
        call.channel?.send(["event": "asking", "message": "Looking in Gmail for the code"])
        let sources = AgentCodes.sources(call.tab?.browser ?? call.browser)
        let end = Date().addingTimeInterval(AgentCodes.patience)
        var strangers = 0
        var found: OneTimeCode?
        while found == nil, Date() < end, call.channel?.gone != true {
            for source in sources where found == nil {
                if case .found(let codes) = await source.read(since: since) {
                    let picked = AgentCodeFit.pick(codes, site: site, since: since)
                    found = picked.code
                    strangers = max(strangers, picked.strangers)
                }
            }
            if found == nil { try? await Task.sleep(for: .seconds(AgentCodes.every)) }
        }
        guard let code = found else {
            let other = strangers > 0 ? ". A code from another sender came, and Broadway left it alone" : ""
            throw PersonRefusal("nothing_kept", "Gmail got no code from \(site) within \(Int(AgentCodes.patience)) s of the page asking\(other). Nothing was filled.",
                                hint: handHint("Type the code you were sent"))
        }
        guard tab.pageAddress == place, !tab.driving else {
            throw PersonRefusal("refused", "The page changed while Broadway looked for the code, so nothing was filled. Look again.")
        }
        return try await fill(call, tab: tab, place: place, code: code.code)
    }

    static func onePasswordItem(_ call: PersonCall, place: URL, site: String, app: Bool) async -> OnePasswordItem? {
        if let used = AgentSignInRecord.item(call.link?.id, site: site) { return used }
        guard app, case .found(let kept) = await OnePasswordLookups.shared.lookup(place) else { return nil }
        let items = Set(kept.compactMap(\.item))
        return items.count == 1 ? items.first : nil
    }

    static func askForCode(_ call: PersonCall, tab: Tab, site: String, title: String) async throws {
        let prefs = call.browser.prefs
        switch AgentSecretPolicy.code(mode: prefs.agentMode, rule: AgentSites.shared.rule(for: site), alwaysAsk: prefs.agentsAskSignIn,
                                      signedInLately: AgentSignInRecord.lately(call.link?.id, site: site)) {
        case .refuse:
            throw PersonRefusal("never_here", "The person never lets agents act on \(site). Leave it.")
        case .go:
            return
        case .ask:
            try await ask(call, tab: tab, site: site, title: title)
        }
    }

    static func ask(_ call: PersonCall, tab: Tab, site: String, title: String) async throws {
        var question = AgentQuestion(kind: .approval(.signIn), title: title)
        question.site = site
        question.yesWord = "Fill"
        question.offersAlways = false
        switch try await PersonAsk.put(question, call: call) {
        case .yes, .always, .picked:
            break
        case .never:
            AgentSites.shared.set(.never, for: site)
            throw PersonRefusal("never_here", "The person said never here. Leave \(site).")
        case .no:
            throw PersonAsk.saidNo
        case .dropped:
            throw PersonAsk.unanswered
        }
        guard tab.pageAddress == call.askedAt, !tab.driving else {
            throw PersonRefusal("refused", "The page changed, so nothing was filled. Look again.")
        }
    }

    static func fill(_ call: PersonCall, tab: Tab, place: URL, code: String) async throws -> [String: Any] {
        let link = call.link
        AgentSeals.keep(code)
        tab.seal(code)
        call.box.acting(tab, "Filling the code")
        _ = await tab.searchValue("(function(){" + AgentCodePage.lookScript + "})()")
        let filled = await tab.searchValue("(function(code){" + AgentCodePage.fillScript + "})(" + Self.literal(code) + ")") as? [String: Any]
        guard let filled, filled["failed"] == nil else {
            throw PersonRefusal("not_found", (filled?["failed"] as? String) ?? "The code box went away, so nothing was filled", hint: "Look at the page again")
        }
        try? await Task.sleep(for: .milliseconds(700))
        var sent = tab.loading || tab.pageAddress != place
        if !sent, let said = await tab.searchValue("(function(){" + AgentCodePage.sendScript + "})()") as? [String: Any] {
            sent = said["sent"] as? Bool == true || said["gone"] as? Bool == true
        }
        if sent { await PersonSignIn.settle(tab) }
        let look = await call.box.look(tab, task: link?.id)
        let message: String
        if !sent {
            message = "Filled the code. Broadway found no button to send it, so look at the page and send it yourself."
        } else if look?.needs == "code" {
            message = "Filled the code and sent it. The page still asks for a code, so it may be wrong or too old. Look at the page, or run broadway handoff \"Type the code you were sent\"."
        } else {
            message = "Filled the code and sent it. The page no longer asks for a code."
        }
        var answer: [String: Any] = ["message": message, "tab": AgentWorkTabs.short(tab.id), "url": AgentSecrets.shown(tab.pageAddress), "title": tab.title]
        if let look { answer["lines"] = look.text() }
        return answer
    }

    private static func literal(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
