import Foundation
import WebKit

enum AgentSecretHand {
    @TaskLocal static var secret: String?
}

enum AgentSecretPolicy {
    enum Verdict: Equatable {
        case go
        case ask(always: Bool)
        case refuse
    }

    static func typing(mode: AgentMode, rule: SiteRule?, alwaysAsk: Bool) -> Verdict {
        if rule == .never { return .refuse }
        if alwaysAsk { return .ask(always: false) }
        switch mode {
        case .bypass: return .go
        case .ask: return .ask(always: false)
        case .auto: return rule == .always ? .go : .ask(always: true)
        }
    }

    static func carrying(_ rules: [SiteRule?]) -> Verdict {
        rules.contains(.never) ? .refuse : .ask(always: false)
    }

    static func code(mode: AgentMode, rule: SiteRule?, alwaysAsk: Bool, signedInLately: Bool) -> Verdict {
        if rule == .never { return .refuse }
        if signedInLately { return .go }
        if !alwaysAsk, mode == .bypass { return .go }
        return .ask(always: false)
    }
}

@MainActor
enum AgentSecretPasses {
    private static var given: [String: Date] = [:]

    static func give(_ key: String) { given[key] = Date() }

    static func take(_ key: String) -> Bool {
        guard let at = given.removeValue(forKey: key) else { return false }
        return Date().timeIntervalSince(at) < 600
    }
}

@MainActor
enum AgentCarry {
    static let plainHint = "For a secret you hold, run broadway type TARGET --secret-env NAME, pipe it in with --secret-stdin, or give --secret-file PATH. Over MCP, give secret_env. Broadway types it and never shows it."

    static let noSecret = ToolOutcome.failure("secret_env is read by broadway mcp from its own environment, and this call came without the value. Nothing was typed", code: .usage,
                                              hint: "Run broadway type TARGET --secret-env NAME in a shell, or update broadway")

    private static let pick = """

    var box = target && target.matches && target.matches('input,textarea,[contenteditable]') ? target : el;
    """

    static let boxScript = AgentPage.find + PageSelection.secretCheck + pick + """
    var input = !!(box.matches && box.matches('input,textarea')) || !!box.isContentEditable;
    var said = name(box) || box.getAttribute('placeholder') || '';
    return { secret: input && broadwaySecret(box), input: input, readonly: !!(box.disabled || box.readOnly), name: said.replace(/\\s+/g, ' ').trim().slice(0, 60), origin: location.origin };
    """

    static let putScript = AgentPage.find + PageSelection.secretCheck + pick + """
    if (!broadwaySecret(box)) return { failed: 'That box is no longer a password box, so nothing was typed', code: 'refused' };
    if (box.disabled || box.readOnly) return { failed: 'That box is read-only', code: 'not_actionable', reason: 'readonly' };
    box.focus();
    var input = box.tagName === 'TEXTAREA' || box.tagName === 'INPUT';
    if (input) {
      var setter = Object.getOwnPropertyDescriptor(box.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype, 'value').set;
      setter.call(box, '');
      box.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContent' }));
      try { box.setSelectionRange(0, 0); } catch (e) {}
      if (!document.execCommand('insertText', false, secret) || box.value !== secret) {
        setter.call(box, secret);
        box.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText' }));
      }
    } else {
      var whole = document.createRange();
      whole.selectNodeContents(box);
      var picked = getSelection();
      picked.removeAllRanges();
      picked.addRange(whole);
      document.execCommand('insertText', false, secret);
    }
    box.dispatchEvent(new Event('change', { bubbles: true }));
    (window.__broadwaySealed = window.__broadwaySealed || new WeakSet()).add(box);
    return { ok: true, landed: input ? box.value === secret : (box.innerText || '').indexOf(secret) >= 0 };
    """

    static let sourceScript = AgentPage.find + PageSelection.secretCheck + """

    var box = el;
    var named = '';
    if (/^(H[1-6]|LABEL|DT|TH|LEGEND)$/.test(box.tagName) || box.getAttribute('role') === 'heading') {
      named = box.innerText || box.textContent || '';
      var next = box.tagName === 'LABEL' && box.control ? box.control : null;
      var stop = false;
      for (var from = box, climb = 0; !next && !stop && from && from !== document.body && climb < 3; from = from.parentElement, climb++) {
        for (var after = from.nextElementSibling; after && !next; after = after.nextElementSibling) {
          if (/^(SCRIPT|STYLE|TEMPLATE)$/.test(after.tagName)) continue;
          if (/^H[1-6]$/.test(after.tagName) || after.getAttribute('role') === 'heading') { stop = true; break; }
          var inner = after.matches('code,pre,kbd,samp,output') ? after : after.querySelector('code,pre,kbd,samp,output');
          var said = String(after.innerText || '').trim();
          if (after.matches('input,textarea,select') && after.value) next = after;
          else if (inner && String(inner.innerText || '').trim()) next = inner;
          else if (said && !/\\s/.test(said) && said.length >= 6) next = after;
        }
      }
      if (!next) return { failed: 'Nothing that looks like a value follows that heading, so nothing was copied', code: 'not_found', hint: 'Give the ref of the value itself' };
      box = next;
    }
    var field = !!(box.matches && box.matches('input,textarea,select'));
    var value = field ? String(box.value || '') : String(box.isContentEditable ? box.innerText : (box.innerText || box.textContent || '')).trim();
    var label = named || (field || box.isContentEditable ? name(box) : (box.getAttribute('aria-label') || box.getAttribute('title') || ''));
    for (var at = box, up = 0; at && up < 4 && !label; at = at.parentElement, up++) {
      for (var before = at.previousElementSibling; before && !label; before = before.previousElementSibling) {
        if (/^(H[1-6]|LABEL|DT|TH|LEGEND)$/.test(before.tagName) || before.getAttribute('role') === 'heading') label = before.innerText || before.textContent || '';
      }
    }
    label = String(label || '').replace(/\\s+/g, ' ').trim().slice(0, 60);
    var flat = value.replace(/\\s+/g, ' ').trim();
    if (!label || flat && (label.indexOf(flat) >= 0 || flat.indexOf(label) >= 0)) label = field ? 'a field' : 'the text shown';
    var out = { name: label, secret: broadwaySecret(box), empty: !value, origin: location.origin };
    if (wanted) out.value = value;
    return out;
    """

    static let textScript = AgentPage.naming + AgentPage.stateScript + """

    var want = String(words || '').replace(/\\s+/g, ' ').trim();
    if (!want) return { failed: 'Give the words of the element to copy from', code: 'usage' };
    var best = null, size = Infinity;
    var all = document.body ? document.body.querySelectorAll('*') : [];
    for (var i = 0; i < all.length; i++) {
      var one = all[i];
      if (/^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE)$/.test(one.tagName) || !seen(one)) continue;
      var text = String(one.innerText || '').replace(/\\s+/g, ' ').trim();
      if (text.indexOf(want) < 0 || text.length >= size) continue;
      best = one;
      size = text.length;
    }
    if (!best) return { failed: 'No element on the page holds "' + want.slice(0, 60) + '"', code: 'not_found' };
    var ref = broadwayRef(best, null);
    broadwayTell(ref);
    return { ref: ref };
    """

    static func site(_ facts: [String: Any], or tab: Tab) -> String? {
        if let origin = facts["origin"] as? String, let url = URL(string: origin), let site = AgentSites.site(of: url) { return site }
        return AgentSites.site(of: tab.pageAddress)
    }

    static func shownName(_ facts: [String: Any], fallback: String) -> String {
        let said = (facts["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return said.isEmpty ? fallback : AgentQuestion.clean(said, limit: 60)
    }
}

@MainActor
extension BrowserToolbox {
    private var agentPrefs: Preferences? { (Browsers.forAgents(keeping: browser) ?? Browsers.front)?.prefs }

    func typeSecret(_ tab: Tab, _ arguments: [String: Any], secret: String, task: UUID?) async -> ToolOutcome {
        if let text = arguments["text"] as? String, !text.isEmpty {
            return .failure("Give the text or a secret, not both. Nothing was typed.", code: .usage)
        }
        if arguments["submit"] as? Bool == true {
            return .failure("A secret is typed without sending the form. Nothing was typed.", code: .usage,
                            hint: "Type it, then send with broadway press Enter or broadway click")
        }
        guard secret.count >= 4 else {
            return .failure("A secret under 4 characters can't be kept out of later answers, so it was not typed", code: .refused, hint: "Ask the person to type it")
        }
        let ref = arguments["ref"] as? String ?? ""
        guard let facts = await inFrame(tab, ref, AgentCarry.boxScript) as? [String: Any] else {
            return .failure("The page gave no answer", code: .noAnswer)
        }
        if facts["failed"] != nil { return pageFailure(facts, tab: tab, ref: ref) }
        let field = AgentCarry.shownName(facts, fallback: "the box")
        guard facts["secret"] as? Bool == true else {
            let what = facts["input"] as? Bool == true ? "\(field) is a plain box" : "That element is not a box to type in"
            return .failure("\(what), so a secret typed there would show in your next look. Nothing was typed.", code: .refused,
                            hint: "Type a secret only into a password box. broadway find --role textbox lists the boxes.")
        }
        if facts["readonly"] as? Bool == true { return .failure("That box is read-only", code: .notActionable) }
        let site = AgentCarry.site(facts, or: tab)
        let place = site ?? "this page"
        if let refused = await secretAsk(.typing, tab: tab, site: site, title: "Type a secret into \(field) on \(place)?", yes: "Type",
                                         key: "type|\(task?.uuidString ?? "")|\(place)|\(field)", task: task) { return refused }
        acting(tab, "Typing")
        AgentSeals.keep(secret)
        tab.seal(secret)
        await mark(tab, ref: ref, task: task)
        guard let said = await inFrame(tab, ref, AgentCarry.putScript, ["secret": secret]) as? [String: Any] else {
            return .failure("The secret was sent, but the page didn't say whether it landed", code: .failed, hint: "Look before you type again", retrySafe: false)
        }
        if said["failed"] != nil { return pageFailure(said, tab: tab, ref: ref) }
        AgentWatchBox.current?.said = "Typed a secret into \(field)" + (AgentRef(ref).frame == nil ? " @\(ref)" : "")
        if said["landed"] as? Bool == false { AgentWatchBox.current?.notes.append("(the box did not take all of it, so it may cut secrets to a length)") }
        return .json(["ok": true])
    }

    enum SecretAsk {
        case typing, carrying
    }

    func secretAsk(_ kind: SecretAsk, tab: Tab, site: String?, sites: [String?] = [], title: String, yes: String, key: String, task: UUID?) async -> ToolOutcome? {
        let verdict: AgentSecretPolicy.Verdict
        switch kind {
        case .typing:
            verdict = AgentSecretPolicy.typing(mode: agentPrefs?.agentMode ?? .auto, rule: AgentSites.shared.rule(for: site), alwaysAsk: agentPrefs?.agentsAskSignIn ?? false)
        case .carrying:
            verdict = AgentSecretPolicy.carrying(sites.map { AgentSites.shared.rule(for: $0) })
        }
        let offersAlways: Bool
        switch verdict {
        case .go:
            return nil
        case .refuse:
            let blocked = sites.compactMap { $0 }.first { AgentSites.shared.rule(for: $0) == .never } ?? site
            return .failure("The person never lets agents act on \(blocked ?? "this site"). Leave it.", code: .neverHere)
        case .ask(let always):
            offersAlways = always
        }
        if AgentSecretPasses.take(key) { return nil }
        guard let task else {
            return .failure("This needs the person's yes, and only a connected agent can ask for it. Nothing was done.", code: .needsTask)
        }
        var question = AgentQuestion(kind: .approval(.signIn), title: AgentQuestion.clean(title, limit: 200))
        question.task = task
        question.tab = tab.id
        question.site = site
        question.yesWord = yes
        question.offersAlways = offersAlways
        let settle = { (answer: AgentAnswer) -> ToolOutcome? in
            switch answer {
            case .yes:
                return nil
            case .always:
                if let site { AgentSites.shared.set(.always, for: site) }
                return nil
            case .never:
                if let site { AgentSites.shared.set(.never, for: site) }
                return .failure("The person said never here. Leave \(site ?? "this site").", code: .neverHere)
            case .no, .dropped, .picked:
                return .failure("The person said not now. Stop this step, and do not try it another way.", code: .saidNo)
            }
        }
        let late = { (answer: AgentAnswer) in
            if settle(answer) == nil { AgentSecretPasses.give(key) }
        }
        guard let answer = await heard(question, tab: tab, join: task, later: late) else {
            return .failure("This waits for the person's yes in Broadway. The question is on their screen: tell them, then run the same command again. Nothing was done.", code: .needsYou)
        }
        return settle(answer)
    }

    func carry(_ tab: Tab, _ arguments: [String: Any], task: UUID?) async -> ToolOutcome {
        guard let task else {
            return .failure("This needs the person's yes, and only a connected agent can ask for it. Nothing was done.", code: .needsTask)
        }
        guard tab.agent, tab.agentTask == task else {
            return .failure("carry works only between your own tabs, and that tab is the person's. Nothing was copied.", code: .notYours)
        }
        let named = (arguments["to_tab"] as? String) ?? (arguments["to-tab"] as? String)
        let goal: Tab
        if let named, !named.isEmpty {
            guard let found = find(["tab": named])?.tab else {
                return .failure("No such tab: \(named)", code: .noTab, hint: "broadway tabs lists yours")
            }
            goal = found
        } else {
            goal = tab
        }
        guard goal.agent, goal.agentTask == task else {
            return .failure("carry works only between your own tabs, and \(AgentWorkTabs.short(goal.id)) is the person's. Nothing was copied.", code: .notYours)
        }
        guard goal.page == nil, goal.isWeb, !goal.asleep else { return .failure("That tab isn't showing a web page", code: .notAPage) }
        guard let to = (arguments["to"] as? String)?.trimmingCharacters(in: .whitespaces), !to.isEmpty else {
            return .failure("carry needs --to: the password box to fill, as a ref or its label", code: .usage)
        }
        let from: String
        let given = AgentTarget(arguments, key: "ref")
        switch await resolve(given, tab: tab, tool: "carry", task: task) {
        case .success(let ref):
            from = ref
        case .failure(let failure):
            guard failure.code == ToolCode.notFound.rawValue, given.ref == nil, let words = given.words,
                  let found = await timed(tab, AgentCarry.textScript, ["words": words]) as? [String: Any] else { return failure }
            if found["failed"] != nil { return pageFailure(found, tab: tab) }
            guard let ref = found["ref"] as? String else { return failure }
            from = ref
        }
        let into: String
        switch await resolve(AgentTarget(ref: AgentTarget.isRef(to) ? AgentTarget.bare(to) : nil, words: AgentTarget.isRef(to) ? nil : to), tab: goal, tool: "type", task: task) {
        case .success(let ref): into = ref
        case .failure(let failure): return failure
        }
        guard let source = await inFrame(tab, from, AgentCarry.sourceScript, ["wanted": false]) as? [String: Any] else {
            return .failure("The page gave no answer", code: .noAnswer)
        }
        if source["failed"] != nil { return pageFailure(source, tab: tab, ref: from) }
        if source["empty"] as? Bool == true { return .failure("That element holds nothing to copy", code: .notFound) }
        guard let box = await inFrame(goal, into, AgentCarry.boxScript) as? [String: Any] else {
            return .failure("The page gave no answer", code: .noAnswer)
        }
        if box["failed"] != nil { return pageFailure(box, tab: goal, ref: into) }
        let field = AgentCarry.shownName(box, fallback: "the box")
        guard box["secret"] as? Bool == true else {
            let what = box["input"] as? Bool == true ? "\(field) is a plain box" : "That element is not a box to type in"
            return .failure("\(what), and carry fills only a password box, so the value never shows in a later look. Nothing was copied.", code: .refused,
                            hint: "Carry into a password box. broadway find --role textbox --tab ID lists the boxes.")
        }
        if box["readonly"] as? Bool == true { return .failure("That box is read-only", code: .notActionable) }
        let fromSite = AgentCarry.site(source, or: tab)
        let toSite = AgentCarry.site(box, or: goal)
        let what = AgentCarry.shownName(source, fallback: "the text shown")
        let fromPlace = fromSite ?? "this page"
        let toPlace = toSite ?? "this page"
        let fromAt = tab.pageAddress
        let toAt = goal.pageAddress
        if let refused = await secretAsk(.carrying, tab: goal, site: toSite, sites: [fromSite, toSite], title: "Copy the value of \(what) on \(fromPlace) into \(field) on \(toPlace)?", yes: "Copy",
                                         key: "carry|\(task.uuidString)|\(fromPlace)|\(what)|\(toPlace)|\(field)", task: task) { return refused }
        guard tab.pageAddress == fromAt, goal.pageAddress == toAt, !tab.driving, !goal.driving else {
            return .failure("A page changed while the person was answering, so nothing was copied. Look again.", code: .refused)
        }
        guard let read = await inFrame(tab, from, AgentCarry.sourceScript, ["wanted": true]) as? [String: Any], read["failed"] == nil,
              let value = read["value"] as? String, !value.isEmpty else {
            return .failure("The value was gone by the time the person said yes, so nothing was copied. Look again.", code: .notFound)
        }
        guard value.count >= 4 else {
            return .failure("A value under 4 characters can't be kept out of later answers, so it was not copied", code: .refused, hint: "Ask the person to type it")
        }
        AgentSeals.keep(value)
        tab.seal(value)
        goal.seal(value)
        acting(goal, "Typing")
        await mark(goal, ref: into, task: task)
        guard let said = await inFrame(goal, into, AgentCarry.putScript, ["secret": value]) as? [String: Any] else {
            return .failure("The value was sent, but the page didn't say whether it landed", code: .failed, hint: "Look before you carry again", retrySafe: false)
        }
        if said["failed"] != nil { return pageFailure(said, tab: goal, ref: into) }
        let size = source["secret"] as? Bool == true ? "" : " of \(value.count) characters"
        var lines = ["Carried a value\(size) from \(what) on \(fromPlace) into \(field) on \(toPlace) in \(AgentWorkTabs.short(goal.id))"]
        if said["landed"] as? Bool == false { lines.append("The box did not take all of it, so it may cut values to a length") }
        var data: [String: Any] = ["message": lines.joined(separator: ". "), "tab": AgentWorkTabs.short(goal.id), "url": AgentSecrets.shown(goal.pageAddress), "title": goal.title, "website": true]
        if let look = await look(goal, task: task) {
            data["lines"] = look.text()
            lines += look.text()
        }
        return ToolOutcome(text: ToolReply.notice + lines.joined(separator: "\n"), data: data)
    }
}
