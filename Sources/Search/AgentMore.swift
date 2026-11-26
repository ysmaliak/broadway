import AppKit
import WebKit

struct AgentKey: Equatable {
    var key: String
    var code: UInt16
    var text: String
    var shift = false
    var control = false
    var option = false
    var command = false

    static let letters: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    static let named: [String: (code: UInt16, text: String)] = AgentPage.keyCodes.merging([
        "Delete": (117, "\u{F728}"), "Home": (115, "\u{F729}"), "End": (119, "\u{F72B}"), "PageUp": (116, "\u{F72C}"), "PageDown": (121, "\u{F72D}"),
        "Space": (49, " "), "ArrowLeft": (123, "\u{F702}"), "ArrowRight": (124, "\u{F703}"), "ArrowDown": (125, "\u{F701}"), "ArrowUp": (126, "\u{F700}"),
    ]) { _, new in new }

    static let aliases: [String: String] = [
        "enter": "Enter", "return": "Enter", "esc": "Escape", "escape": "Escape", "tab": "Tab", "space": "Space", "spacebar": "Space",
        "backspace": "Backspace", "delete": "Delete", "del": "Delete", "up": "ArrowUp", "down": "ArrowDown", "left": "ArrowLeft", "right": "ArrowRight",
        "arrowup": "ArrowUp", "arrowdown": "ArrowDown", "arrowleft": "ArrowLeft", "arrowright": "ArrowRight", "home": "Home", "end": "End",
        "pageup": "PageUp", "pagedown": "PageDown",
    ]

    static func parse(_ said: String) -> AgentKey? {
        let parts = said == "+" ? ["+"] : said.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last, !last.isEmpty else { return nil }
        var found: AgentKey
        let given = aliases[last.lowercased()] ?? last
        if let known = named[given] {
            found = AgentKey(key: given == "Space" ? " " : given, code: known.code, text: known.text)
        } else if last.count == 1, let letter = last.lowercased().first, let code = letters[letter] {
            found = AgentKey(key: last, code: code, text: last)
        } else {
            return nil
        }
        for part in parts.dropLast() {
            switch part.lowercased() {
            case "shift": found.shift = true
            case "control", "ctrl": found.control = true
            case "alt", "option": found.option = true
            case "meta", "command", "cmd": found.command = true
            default: return nil
            }
        }
        if found.shift, found.key.count == 1 { found.text = found.key.uppercased() }
        return found
    }

    var plain: Bool { !shift && !control && !option && !command }

    var touchesClipboard: Bool { (command || control) && ["v", "c", "x"].contains(key.lowercased()) }

    var flags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if shift { flags.insert(.shift) }
        if control { flags.insert(.control) }
        if option { flags.insert(.option) }
        if command { flags.insert(.command) }
        if (123...126).contains(code) { flags.insert(.numericPad) }
        if text.unicodeScalars.first.map({ (0xF700...0xF8FF).contains($0.value) }) == true { flags.insert(.function) }
        return flags
    }

    var script: [String: Any] { ["key": key, "shift": shift, "control": control, "option": option, "command": command] }
}

extension AgentPage {
    static let comboScript = """
    var el = document.activeElement || document.body;
    var options = { key: key, code: key.length === 1 ? 'Key' + key.toUpperCase() : key, bubbles: true, cancelable: true,
                    shiftKey: shift, ctrlKey: control, altKey: option, metaKey: command };
    el.dispatchEvent(new KeyboardEvent('keydown', options));
    el.dispatchEvent(new KeyboardEvent('keyup', options));
    return { ok: true };
    """

    static let shownScript = find + """
    var box = el.getBoundingClientRect(), look = getComputedStyle(el);
    return { shown: el.isConnected && box.width > 0 && box.height > 0 && look.visibility !== 'hidden' && look.display !== 'none' && Number(look.opacity) > 0 };
    """

    static let dragScript = find + """
    var from = el;
    var toGot = broadwayGet(to);
    if (toGot.failed) return toGot;
    var target = toGot.el;
    from.scrollIntoView({ block: 'center', inline: 'center' });
    var a = from.getBoundingClientRect(), b = target.getBoundingClientRect();
    var sx = a.left + a.width / 2, sy = a.top + a.height / 2, tx = b.left + b.width / 2, ty = b.top + b.height / 2;
    function mouse(node, type, x, y, buttons) {
      var o = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, button: 0, buttons: buttons, view: window, pointerId: 1, isPrimary: true, pointerType: 'mouse' };
      node.dispatchEvent(new PointerEvent('pointer' + type, o));
      node.dispatchEvent(new MouseEvent('mouse' + type, o));
    }
    var transfer = new DataTransfer();
    function drag(node, type, x, y) {
      var event = new DragEvent(type, { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, dataTransfer: transfer });
      if (!event.dataTransfer) Object.defineProperty(event, 'dataTransfer', { value: transfer });
      return node.dispatchEvent(event);
    }
    mouse(from, 'down', sx, sy, 1);
    var html = from.draggable || !!(from.closest && from.closest('[draggable=true]'));
    if (html) drag(from, 'dragstart', sx, sy);
    for (var i = 1; i <= 6; i++) {
      var x = sx + (tx - sx) * i / 6, y = sy + (ty - sy) * i / 6;
      mouse(document.elementFromPoint(x, y) || target, 'move', x, y, 1);
    }
    if (html) {
      drag(target, 'dragenter', tx, ty);
      drag(target, 'dragover', tx, ty);
      drag(target, 'drop', tx, ty);
      drag(from, 'dragend', tx, ty);
    }
    mouse(document.elementFromPoint(tx, ty) || target, 'up', tx, ty, 0);
    target.dispatchEvent(new MouseEvent('click', { bubbles: false, cancelable: true, clientX: tx, clientY: ty, view: window, detail: 0 }));
    return { ok: true, html: html };
    """

    static let listScript = find + """

    var subject = target || el;
    return subject.tagName === 'SELECT' || (subject.tagName !== 'INPUT' && subject.tagName !== 'TEXTAREA' && !subject.isContentEditable && /^(combobox|listbox)$/.test((subject.getAttribute('role') || '').toLowerCase()));
    """

    static let selectScript = find + PageSelection.secretCheck + """

    var subject = target || el;
    if (broadwaySecret(subject)) return { failed: 'Agents never type in password, card or code fields. Ask the person to.', code: 'secret_field' };
    var boxed = subject.tagName === 'INPUT' || subject.tagName === 'TEXTAREA';
    if (subject.tagName === 'SELECT' || (!boxed && !subject.isContentEditable && /^(combobox|listbox)$/.test((subject.getAttribute('role') || '').toLowerCase()))) {
      return { failed: 'That element is a dropdown, and select only selects text', code: 'not_actionable', reason: 'dropdown' };
    }
    var picked = '';
    if (subject.tagName === 'INPUT' || subject.tagName === 'TEXTAREA') {
      var value = subject.value || '', at = text ? value.indexOf(text) : 0;
      if (at < 0) return { failed: 'That text is not in that element.' };
      subject.focus();
      subject.setSelectionRange(at, text ? at + text.length : value.length);
      picked = value.substring(at, text ? at + text.length : value.length);
    } else {
      var range = document.createRange();
      if (text) {
        var walker = document.createTreeWalker(subject, NodeFilter.SHOW_TEXT), node, found = false;
        while ((node = walker.nextNode())) {
          var i = node.data.indexOf(text);
          if (i >= 0) { range.setStart(node, i); range.setEnd(node, i + text.length); found = true; break; }
        }
        if (!found) return { failed: 'That text is not in that element, or runs across parts of it.' };
      } else {
        range.selectNodeContents(subject);
      }
      var selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      picked = selection.toString();
    }
    if (!picked) return { failed: 'Nothing got selected, as that text is not shown on the page', code: 'not_found' };
    return { selected: picked.slice(0, 2000) };
    """

    static let pageSizeScript = """
    var d = document.documentElement, b = document.body || d;
    return { width: Math.max(d.scrollWidth, b.scrollWidth, innerWidth), height: Math.max(d.scrollHeight, b.scrollHeight, innerHeight) };
    """
}

extension String {
    var fullStopped: String {
        guard let last = trimmingCharacters(in: .whitespacesAndNewlines).last, !".?!…".contains(last) else { return self }
        return self + "."
    }
}

enum AgentFill {
    static func truthy(_ value: Any) -> Bool? {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        switch (value as? String)?.lowercased() {
        case "true", "on", "yes", "1", "checked": return true
        case "false", "off", "no", "0", "unchecked": return false
        default: return nil
        }
    }

    static func refOf(_ key: String) -> String? {
        let bare = key.hasPrefix("@") ? String(key.dropFirst()) : key
        return bare.range(of: "^(f[0-9]+\\.)?e[0-9]+$", options: .regularExpression) != nil ? bare : nil
    }

    struct Miss: Error { let said: String }

    static func match(_ key: String, in elements: [[String: Any]]) -> Result<[String: Any], Miss> {
        if let ref = refOf(key) {
            guard let found = elements.first(where: { $0["ref"] as? String == ref }) else { return .failure(Miss(said: "\(key) isn't on the page now. Take a new snapshot.")) }
            return .success(found)
        }
        let fillable: Set<String> = ["textbox", "searchbox", "combobox", "checkbox", "radio", "switch", "slider", "spinbutton"]
        let named = elements.filter { fillable.contains($0["role"] as? String ?? "") && ($0["name"] as? String ?? "").caseInsensitiveCompare(key) == .orderedSame }
        let near = named.isEmpty ? elements.filter { fillable.contains($0["role"] as? String ?? "") && ($0["name"] as? String ?? "").localizedCaseInsensitiveContains(key) } : named
        guard near.count == 1, let found = near.first else {
            return .failure(Miss(said: near.isEmpty ? "No field is labelled \(key). Use a ref from broadway snapshot." : "Several fields match \(key): \(near.compactMap { $0["ref"] as? String }.map { "@" + $0 }.joined(separator: ", ")). Use a ref."))
        }
        return .success(found)
    }
}

extension BrowserToolbox {
    func elements(_ tab: Tab, task: UUID?) async -> [[String: Any]]? {
        await everything(tab)
    }

    func findElements(_ tab: Tab, _ arguments: [String: Any], task: UUID?) async -> ToolOutcome {
        let words = (arguments["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let role = (arguments["role"] as? String ?? "").lowercased()
        guard !words.isEmpty || !role.isEmpty else { return .failure("locate needs text, a role, or both") }
        acting(tab, "Reading")
        guard let all = await elements(tab, task: task) else { return .failure("The page gave no answer") }
        let found = all.filter { item in
            (role.isEmpty || (item["role"] as? String ?? "") == role)
                && (words.isEmpty || ["name", "value"].contains { (item[$0] as? String ?? "").localizedCaseInsensitiveContains(words) })
        }
        let limit = min(max(Int(arguments["limit"] as? Double ?? 20), 1), 200)
        let shown = Array(found.prefix(limit))
        let lines = shown.map { "@\($0["ref"] as? String ?? "") \($0["role"] as? String ?? "") \"\($0["name"] as? String ?? "")\"" }
        return ToolOutcome(text: "\(ToolReply.notice)\(lines.joined(separator: "\n"))", data: ["elements": shown, "count": found.count, "website": true])
    }

    func fill(_ tab: Tab, _ arguments: [String: Any], task: UUID?, browser: Browser) async -> ToolOutcome {
        guard let fields = arguments["fields"] as? [String: Any], !fields.isEmpty, fields.count <= 50 else {
            return .failure("fill takes one to fifty fields, as {\"@e4\": \"Sam\", \"Country\": \"Spain\"}.")
        }
        guard let all = await elements(tab, task: task) else { return .failure("The page gave no answer", code: .noAnswer) }
        var plan: [(key: String, item: [String: Any], value: Any)] = []
        for key in fields.keys.sorted() {
            switch AgentFill.match(key, in: all) {
            case .success(let item): plan.append((key, item, fields[key] ?? ""))
            case .failure(let why): return .failure("\(why.said.fullStopped) Nothing was filled.")
            }
        }
        var filled: [String] = []
        for step in plan {
            let ref = step.item["ref"] as? String ?? ""
            let role = step.item["role"] as? String ?? ""
            let said: ToolOutcome
            switch role {
            case "checkbox", "switch", "radio":
                guard let wanted = AgentFill.truthy(step.value) else {
                    return .failure("\(step.key) is a \(role): give true or false. Filled so far: \(filled.isEmpty ? "nothing" : filled.joined(separator: ", ")).")
                }
                let now = step.item["checked"] as? Bool == true
                if role == "radio", !wanted { said = .text("Left") } else if now == wanted { said = .text("Already so") } else {
                    said = await click(tab, ref: ref, final: nil, task: task, browser: browser)
                }
            case "combobox" where step.item["options"] != nil:
                let text = "\(step.value)"
                let options = step.item["options"] as? [[String: Any]] ?? []
                let value = options.first { $0["value"] as? String == text }?["value"] as? String
                    ?? options.first { ($0["label"] as? String ?? "").caseInsensitiveCompare(text) == .orderedSame }?["value"] as? String
                guard let value else { return .failure("\(step.key) has no option \(text). Filled so far: \(filled.isEmpty ? "nothing" : filled.joined(separator: ", ")).") }
                said = await act("choose", ["tab": arguments["tab"] ?? "", "ref": ref, "value": value], task: task)
            case "textbox", "searchbox", "combobox", "spinbutton":
                if step.item["hidden"] as? Bool == true { return .failure("\(step.key) is a password, card or code field: agents never type in password, card or code fields. Filled so far: \(filled.isEmpty ? "nothing" : filled.joined(separator: ", ")).") }
                said = await act("type", ["tab": arguments["tab"] ?? "", "ref": ref, "text": "\(step.value)", "replace": true], task: task)
            default:
                return .failure("\(step.key) is a \(role.isEmpty ? "thing" : role), not a field fill can set. Filled so far: \(filled.isEmpty ? "nothing" : filled.joined(separator: ", ")).")
            }
            if said.failed {
                return .failure("\(step.key): \((said.text ?? "That didn't work").fullStopped) Filled so far: \(filled.isEmpty ? "nothing" : filled.joined(separator: ", ")).")
            }
            filled.append(step.key)
        }
        return ToolOutcome(text: "Filled \(filled.joined(separator: ", "))", data: ["filled": filled])
    }

    func drag(_ tab: Tab, _ arguments: [String: Any], task: UUID?, browser: Browser) async -> ToolOutcome {
        let ref = arguments["ref"] as? String ?? ""
        let given = arguments["to"] as? String ?? ""
        let pointed = pointAt.removeValue(forKey: tab.id)
        if let end = Self.spotted(given) { return await drag(tab, ref: ref, from: pointed, to: end, final: arguments["final"] as? String, task: task) }
        var to = AgentTarget.bare(given)
        if !AgentTarget.isRef(given) {
            switch await resolve(AgentTarget(words: given.isEmpty ? nil : given), tab: tab, tool: "drag") {
            case .failure(let failure): return failure
            case .success(let found): to = found
            }
        }
        guard AgentRef(ref).frame == AgentRef(to).frame else { return .failure("Both ends of a drag must be in the same frame", code: .usage) }
        let (_, failure) = await spot(tab, ref: ref)
        if let failure { return failure }
        guard let found = await inFrame(tab, to, AgentPage.factsScript, ["submit": false]) as? [String: Any] else { return .failure("The page gave no answer", code: .noAnswer) }
        if found["failed"] != nil { return pageFailure(found, tab: tab, ref: to) }
        let place = tab.pageAddress
        let decided = await decide(ActionFacts(found), final: arguments["final"] as? String, tab: tab, task: task)
        if let refused = decided.refused { return refused }
        guard tab.pageAddress == place else { return .failure("The page changed while the person was answering, so nothing was dragged. Look again.") }
        acting(tab, "Dragging")
        await mark(tab, ref: ref, task: task)
        return outcome(await inFrame(tab, ref, AgentPage.dragScript, ["to": AgentRef(to).ref]) as? [String: Any], tab: tab, ref: ref)
    }

    static func spotted(_ text: String) -> CGPoint? {
        let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let x = parts[0], let y = parts[1], x.isFinite, y.isFinite, x >= 0, y >= 0 else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func drag(_ tab: Tab, ref: String, from pointed: AgentAim?, to end: CGPoint, final: String?, task: UUID?) async -> ToolOutcome {
        if let refused = notMine(tab, task: task) { return refused }
        guard tab.agent, AgentRef(ref).frame == nil else { return .failure("A drag to a point needs a tab of your own and no frame. Use open.", code: .notYours) }
        var start = pointed?.view
        if start == nil {
            let (spotted, failure) = await spot(tab, ref: ref)
            if let failure { return failure }
            let zoom = Double(max(tab.web.pageZoom, 0.1))
            if let x = spotted?["x"] as? Double, let y = spotted?["y"] as? Double { start = CGPoint(x: x * zoom, y: y * zoom) }
        }
        guard let start else { return .failure("That element has no place on screen", code: .notActionable) }
        let picture = pictureScale(tab, task: task)
        let stop = CGPoint(x: end.x / picture, y: end.y / picture)
        let zoom = max(tab.web.pageZoom, 0.1)
        guard let under = await timed(tab, AgentPage.pointScript, ["x": stop.x / zoom, "y": stop.y / zoom], seconds: 5) as? [String: Any] else {
            return .failure("The page gave no answer", code: .noAnswer)
        }
        if let failed = under["failed"] as? String { return .failure(failed, code: under["code"] as? String ?? "not_found") }
        guard let to = under["ref"] as? String,
              let found = await inFrame(tab, to, AgentPage.factsScript, ["submit": false]) as? [String: Any] else { return .failure("The page gave no answer", code: .noAnswer) }
        if found["failed"] != nil { return pageFailure(found, tab: tab, ref: to) }
        let place = tab.pageAddress
        let decided = await decide(ActionFacts(found), final: final, tab: tab, task: task)
        if let refused = decided.refused { return refused }
        guard tab.pageAddress == place else { return .failure("The page changed while the person was answering, so nothing was dragged. Look again.") }
        let view = tab.web
        guard let window = view.window else { return .failure("That page has no view to drag in", code: .unseen) }
        acting(tab, "Dragging")
        await mark(tab, ref: ref, task: task)
        point(tab, ["x": stop.x - 1, "y": stop.y - 1, "width": 2, "height": 2], .click, task: task)
        let middle = CGPoint(x: (start.x + stop.x) / 2, y: (start.y + stop.y) / 2)
        let steps: [(NSEvent.EventType, CGPoint)] = [(.leftMouseDown, start), (.leftMouseDragged, middle), (.leftMouseDragged, stop), (.leftMouseUp, stop)]
        for (type, spot) in steps {
            let at = view.convert(NSPoint(x: spot.x, y: view.isFlipped ? spot.y : view.bounds.height - spot.y), to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { continue }
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        let what = under["what"] as? String ?? "the page"
        let begun = pointed.map { "from \(Int(($0.view.x * picture).rounded())),\(Int(($0.view.y * picture).rounded()))" } ?? "@\(ref)"
        AgentWatchBox.current?.said = "Dragged \(begun) to \(what) at \(Int(end.x.rounded())),\(Int(end.y.rounded()))"
        return .text("Dragged")
    }

    func selectText(_ tab: Tab, _ arguments: [String: Any]) async -> ToolOutcome {
        acting(tab, "Selecting")
        let ref = arguments["ref"] as? String ?? ""
        let text = arguments["text"] as? String ?? ""
        let said = await inFrame(tab, ref, AgentPage.selectScript, ["text": text]) as? [String: Any]
        return dropdown(outcome(said, tab: tab, ref: ref), said, ref: ref, text: text)
    }

    func dropdown(_ failure: ToolOutcome, _ said: [String: Any]?, ref: String, text: String) -> ToolOutcome {
        guard said?["reason"] as? String == "dropdown" else { return failure }
        var failure = failure
        let option = text.isEmpty ? "OPTION" : AgentChange.cell(text, most: 80)
        failure.hint = "Pick one of its options with broadway choose @\(ref) \"\(option)\""
        return failure
    }

    func resize(_ tab: Tab, _ arguments: [String: Any], task: UUID?) async -> ToolOutcome {
        if let refused = notMine(tab, task: task) { return refused }
        guard tab.agent else { return .failure("Only tabs an agent opened can be resized. Use open for a tab of your own.", code: .notYours) }
        let width = arguments["width"] as? Double ?? 1280
        let height = arguments["height"] as? Double ?? 800
        guard (320...3840).contains(width), (320...2400).contains(height) else { return .failure("A page is 320 to 3840 points wide and 320 to 2400 high") }
        let web = tab.web
        web.autoresizingMask = []
        web.setFrameSize(NSSize(width: width, height: height))
        try? await Task.sleep(for: .milliseconds(200))
        let size = await PageSelection.run(tab, "return { width: innerWidth, height: innerHeight };") as? [String: Any]
        return .json(["width": size?["width"] ?? width, "height": size?["height"] ?? height])
    }

    func settle(_ tab: Tab, _ arguments: [String: Any]) async -> ToolOutcome? {
        let part = arguments["request"] as? String ?? ""
        let idle = arguments["idle"] as? Bool == true
        guard idle || !part.isEmpty else { return nil }
        let began = Date()
        let cap = min(arguments["seconds"] as? Double ?? 10, Self.waitMost)
        let limit = began.addingTimeInterval(cap)
        let start = tab.devLog.sequence
        let lately = Date().addingTimeInterval(-10)
        repeat {
            let requests = tab.devLog.entries.filter { $0.kind == .request }
            var pause = AgentSettleRule.step
            if !part.isEmpty {
                if let hit = requests.first(where: { ($0.sequence > start || $0.recorded >= lately) && $0.url.contains(part) }) {
                    return .json(["ok": true, "url": AgentSecrets.diagnosticURL(hit.url), "status": hit.status, "failed": hit.failed, "website": true])
                }
            } else {
                let quietFor = Date().timeIntervalSince(requests.last?.recorded ?? .distantPast)
                if !tab.loading, quietFor >= 0.5 {
                    return .json(["ok": true, "title": tab.title, "url": AgentSecrets.shown(tab.pageAddress)])
                }
                pause = AgentSettleRule.pause(elapsed: Date().timeIntervalSince(began), quietFor: quietFor, busy: 0, navigating: tab.loading, cap: cap)
            }
            try? await Task.sleep(for: .seconds(pause))
        } while Date() < limit
        return .failure("Timed out waiting. Nothing was repeated.")
    }
}
