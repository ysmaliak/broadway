import Foundation
import WebKit

struct FormField: Equatable, Identifiable {
    struct Option: Equatable {
        var value: String
        var text: String
    }

    var frame = ""
    var origin = ""
    var index = 0
    var type = "text"
    var autocomplete = ""
    var name = ""
    var htmlID = ""
    var label = ""
    var placeholder = ""
    var inputmode = ""
    var maxLength = 0
    var filled = false
    var group = 0
    var focused = false
    var options: [Option] = []
    var singles = 0
    var count = 0

    var id: String { "\(frame):\(index)" }

    init(frame: String = "", origin: String = "", index: Int = 0, type: String = "text", autocomplete: String = "",
         name: String = "", htmlID: String = "", label: String = "", placeholder: String = "", maxLength: Int = 0,
         filled: Bool = false, group: Int = 1, options: [Option] = [], singles: Int = 0, count: Int = 0) {
        self.frame = frame
        self.origin = origin
        self.index = index
        self.type = type
        self.autocomplete = autocomplete
        self.name = name
        self.htmlID = htmlID
        self.label = label
        self.placeholder = placeholder
        self.maxLength = maxLength
        self.filled = filled
        self.group = group
        self.options = options
        self.singles = singles
        self.count = count
    }

    init?(page: [String: Any], frame: String = "", origin: String = "", focused: Int? = nil) {
        guard let index = page["index"] as? Int else { return nil }
        self.index = index
        self.frame = frame
        self.origin = origin
        type = page["type"] as? String ?? "text"
        autocomplete = page["autocomplete"] as? String ?? ""
        name = page["name"] as? String ?? ""
        htmlID = page["id"] as? String ?? ""
        label = page["label"] as? String ?? ""
        placeholder = page["placeholder"] as? String ?? ""
        inputmode = page["inputmode"] as? String ?? ""
        maxLength = page["maxLength"] as? Int ?? 0
        filled = page["filled"] as? Bool ?? false
        group = page["group"] as? Int ?? 0
        singles = page["singles"] as? Int ?? 0
        count = page["count"] as? Int ?? 0
        self.focused = focused == index
        options = (page["options"] as? [[String: Any]] ?? []).map {
            Option(value: $0["value"] as? String ?? "", text: $0["text"] as? String ?? "")
        }
    }

    var title: String {
        for text in [label, placeholder, name, htmlID] where !text.isEmpty { return String(text.prefix(60)) }
        return "Box"
    }

    var words: String {
        var joined = ""
        for character in [name, htmlID, label, placeholder].joined(separator: " ") {
            if character.isUppercase, joined.last?.isLowercase == true { joined.append(" ") }
            joined.append("_-[].:/()*".contains(character) ? " " : character)
        }
        return joined.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
    }
}

enum FormValueKind: String, CaseIterable {
    case fullName, givenName, familyName, organization, jobTitle, email, phone
    case street, addressLine1, addressLine2, city, region, postal, country
    case cardName, cardNumber, cardExpiry, cardExpiryMonth, cardExpiryYear, cardCode

    var isCard: Bool {
        switch self {
        case .cardName, .cardNumber, .cardExpiry, .cardExpiryMonth, .cardExpiryYear, .cardCode: return true
        default: return false
        }
    }
}

enum FormStay: String {
    case secret, bank, identity, money, birth, demographic, consent, code, other
}

enum FieldVerdict: Equatable {
    case fill(FormValueKind)
    case stay(FormStay)
    case ignored
}

enum FormClassifier {
    private static let ignored: Set<String> = ["hidden", "submit", "button", "reset", "image", "file", "range", "color"]
    private static let tokens: [String: FieldVerdict] = [
        "name": .fill(.fullName), "given-name": .fill(.givenName), "family-name": .fill(.familyName),
        "organization": .fill(.organization), "organization-title": .fill(.jobTitle),
        "email": .fill(.email), "tel": .fill(.phone), "tel-national": .fill(.phone),
        "street-address": .fill(.street), "address-line1": .fill(.addressLine1), "address-line2": .fill(.addressLine2),
        "address-level1": .fill(.region), "address-level2": .fill(.city), "postal-code": .fill(.postal),
        "country": .fill(.country), "country-name": .fill(.country),
        "cc-name": .fill(.cardName), "cc-number": .fill(.cardNumber), "cc-exp": .fill(.cardExpiry),
        "cc-exp-month": .fill(.cardExpiryMonth), "cc-exp-year": .fill(.cardExpiryYear), "cc-csc": .fill(.cardCode),
        "one-time-code": .stay(.code), "username": .stay(.other), "current-password": .stay(.secret),
        "new-password": .stay(.secret), "bday": .stay(.birth), "bday-day": .stay(.birth), "bday-month": .stay(.birth),
        "bday-year": .stay(.birth), "sex": .stay(.demographic), "transaction-amount": .stay(.money),
    ]
    private static let exclusions: [(FormStay, String)] = [
        (.secret, #"pass ?word|passcode|secret|api ?key|\btoken\b|\bpin\b"#),
        (.bank, #"\biban\b|\bbic\b|routing|sort ?code|swift|\bbank|account ?(number|no)\b|\bacct\b"#),
        (.identity, #"\bssn\b|social ?security|passport|driver|licen[cs]e|national ?id|\btax\b|\bvat\b|\bein\b|\bnif\b|\bdni\b|\bid ?(number|no)\b"#),
        (.money, #"amount|price|salary|income|donation|\btip\b|budget|revenue"#),
        (.birth, #"birth|\bdob\b|\bbday\b|\bage\b"#),
        (.demographic, #"gender|\bsex\b|pronoun|ethnic|\brace\b|religio|marital"#),
        (.consent, #"consent|\bagree|\bterms\b|\baccept|newsletter|subscribe|opt ?in"#),
        (.other, #"captcha|search|coupon|promo|voucher|\bgift|comment|message|\bnotes?\b|user ?name|\blogin\b|nickname|\bsubject\b|file ?name|display ?name|project"#),
    ]
    private static let inclusions: [(FormValueKind, String)] = [
        (.cardNumber, #"card ?(number|num|no)\b|cardnumber|\bccnum|\bcc ?number|\bpan\b|numero de carte|kartennummer"#),
        (.cardCode, #"\bcvc2?\b|\bcvv2?\b|\bcsc\b|security ?code|card ?code|verification ?value"#),
        (.cardExpiryMonth, #"exp[a-z]* ?(date ?)?(month|mm)\b|cc ?exp ?month"#),
        (.cardExpiryYear, #"exp[a-z]* ?(date ?)?(year|yy+)\b|cc ?exp ?year"#),
        (.cardExpiry, #"\bexp(iry|iration|ires)?\b|\bmm ?/? ?yy|ablaufdatum"#),
        (.cardName, #"name ?on ?(the ?)?card|card ?holder|cardholder|card ?name|\bcc ?name"#),
        (.email, #"e ?mail|courriel|correo"#),
        (.phone, #"phone|mobile|\btel\b|telefon|telefono|telephone|portable"#),
        (.givenName, #"first ?name|given ?name|\bfname\b|forename|vorname|prenom"#),
        (.familyName, #"last ?name|family ?name|surname|\blname\b|nachname|apellido|nom de famille"#),
        (.organization, #"company|organi[sz]ation|\bbusiness\b|employer|\bfirma\b|societe|empresa"#),
        (.jobTitle, #"job ?title|\bposition\b|\brole\b|occupation"#),
        (.addressLine2, #"address ?(line)? ?2|\baddr ?2|address ?two|apartment|\bapt\b|\bsuite\b|\bunit\b|\bbuilding\b|\bfloor\b|adresszusatz"#),
        (.postal, #"\bzip\b|zip ?code|postal|post ?code|postcode|\bplz\b"#),
        (.addressLine1, #"address ?(line)? ?1|\baddr ?1|\bstreet|address|\baddr\b|strasse|adresse|direccion"#),
        (.city, #"\bcity\b|\btown\b|locality|\bstadt\b|\bort\b|\bville\b|ciudad|suburb"#),
        (.region, #"\bstate\b|province|\bregion\b|county|bundesland|\bestado\b"#),
        (.country, #"country|\bland\b|\bpays\b|\bpais\b"#),
        (.fullName, #"full ?name|your ?name|\bname\b|\bnom\b|\bnombre\b"#),
    ]

    static func verdict(_ field: FormField) -> FieldVerdict {
        if ignored.contains(field.type) { return .ignored }
        if field.type == "password" { return .stay(.secret) }
        if field.type == "checkbox" || field.type == "radio" { return .stay(.consent) }
        for token in field.autocomplete.split(separator: " ").map(String.init) {
            if let verdict = tokens[token] { return verdict }
        }
        if isCode(field) { return .stay(.code) }
        if ["date", "datetime-local", "month", "week", "time", "search"].contains(field.type) { return .stay(.other) }
        if field.type == "email" { return .fill(.email) }
        let guess = fromWords(field.words)
        if field.type == "tel", guess == .stay(.other) { return .fill(.phone) }
        return guess
    }

    private static func fromWords(_ words: String) -> FieldVerdict {
        for (stay, pattern) in exclusions where matches(words, pattern) { return .stay(stay) }
        for (kind, pattern) in inclusions where matches(words, pattern) { return .fill(kind) }
        return .stay(.other)
    }

    static func isCode(_ field: FormField) -> Bool {
        if field.autocomplete.split(separator: " ").contains("one-time-code") { return true }
        guard ["text", "tel", "number", "password"].contains(field.type) else { return false }
        if field.singles >= 4, field.maxLength == 1 { return true }
        let words = field.words
        guard matches(words, #"\botp\b|one ?time|verification ?code|verify ?code|\b2fa\b|\bmfa\b|two ?factor|auth(entication)? ?code|sms ?code|\btotp\b|\bcode\b"#),
              !matches(words, #"coupon|promo|voucher|\bgift|\bzip\b|postal|post ?code|country|discount|referral|invite|\bcard\b|\bcvc\b|\bcvv\b|area ?code|dial"#)
        else { return false }
        if matches(words, #"security ?code"#) {
            return field.maxLength >= 5 || (field.maxLength == 0 && field.count <= 2)
        }
        return field.maxLength <= 12
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

enum FormFieldScript {
    static let relay = "broadwayFields"

    static let source = """
    (function () {
      if (window.__broadwayFields) return;
      var token = Math.random().toString(36).slice(2) + Date.now().toString(36);
      var isTop = window === window.top;
      var seen = [];
      var filling = null;
      var sent = [];
      var answered = [];
      var answerKinds = ['text', 'email', 'tel', 'number', 'url', 'date', 'datetime-local', 'month', 'week', 'time', 'select'];
      var answerRefused = /(^|\\s)(off|one-time-code|new-password|current-password|cc-[a-z-]+)(\\s|$)/;
      var holdEnter = false;
      var skipped = ['hidden', 'submit', 'button', 'reset', 'image', 'file', 'range', 'color'];
      var nativeValue = {
        input: Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value'),
        textarea: Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value'),
        select: Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value')
      };

      function post(message) {
        message.token = token;
        try { window.webkit.messageHandlers.\(relay).postMessage(message); } catch (e) {}
      }
      function tag(el) { return (el.tagName || '').toLowerCase(); }
      function kind(el) { return tag(el) === 'input' ? (el.type || 'text').toLowerCase() : tag(el); }
      function box(el) { return !!el && ['input', 'select', 'textarea'].indexOf(tag(el)) >= 0; }
      function shown(el) {
        var r = el.getBoundingClientRect();
        if (r.width < 1 || r.height < 1) return false;
        var style = getComputedStyle(el);
        return style.visibility !== 'hidden' && style.display !== 'none';
      }
      function usable(el) { return box(el) && !el.disabled && !el.readOnly && skipped.indexOf(kind(el)) < 0 && shown(el); }
      function labelled(el) {
        var out = [];
        try { (el.labels || []).forEach(function (l) { out.push(l.textContent || ''); }); } catch (e) {}
        var by = el.getAttribute('aria-labelledby');
        if (by) by.split(/\\s+/).forEach(function (id) {
          var l = document.getElementById(id);
          if (l) out.push(l.textContent || '');
        });
        out.push(el.getAttribute('aria-label') || '');
        return out.join(' ').replace(/\\s+/g, ' ').trim().slice(0, 200);
      }
      function empty(el) {
        if (tag(el) === 'select') return el.selectedIndex <= 0 || !el.value;
        if (kind(el) === 'checkbox' || kind(el) === 'radio') return !el.checked;
        return !el.value;
      }
      function scope(el) { return el.form || (el.closest && el.closest('form')) || document; }
      function group(el) {
        var form = scope(el);
        if (form === document) return 0;
        return Array.prototype.indexOf.call(document.forms, form) + 1;
      }
      function peers(el) {
        return Array.prototype.filter.call(scope(el).querySelectorAll('input, select, textarea'), usable);
      }
      function singles(el) {
        if (el.maxLength !== 1) return 0;
        return peers(el).filter(function (other) { return other.maxLength === 1; }).length;
      }
      function options(el) {
        if (tag(el) !== 'select') return [];
        return Array.prototype.slice.call(el.options, 0, 400).map(function (o) {
          return { value: o.value, text: (o.textContent || '').trim().slice(0, 80) };
        });
      }
      function describe(el, index) {
        return {
          index: index, type: kind(el), autocomplete: (el.getAttribute('autocomplete') || '').toLowerCase(),
          name: el.getAttribute('name') || '', id: el.id || '', label: labelled(el),
          placeholder: el.getAttribute('placeholder') || '', inputmode: el.getAttribute('inputmode') || '',
          maxLength: el.maxLength > 0 ? el.maxLength : 0, filled: !empty(el), group: group(el), options: options(el),
          singles: singles(el), count: peers(el).length
        };
      }
      function candidates() {
        var radios = {};
        return Array.prototype.filter.call(document.querySelectorAll('input, select, textarea'), function (el) {
          if (!usable(el)) return false;
          if (kind(el) !== 'radio' || !el.name) return true;
          if (radios[el.name]) return false;
          radios[el.name] = true;
          return true;
        });
      }
      function put(el, value) {
        var setter = nativeValue[tag(el)];
        if (tag(el) === 'select') {
          var known = Array.prototype.some.call(el.options, function (o) { return o.value === value; });
          if (!known) return false;
        }
        setter.set.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      }
      function mark(el, entry, colour) {
        if (!colour) return;
        entry.image = el.style.getPropertyValue('background-image');
        entry.repeat = el.style.getPropertyValue('background-repeat');
        entry.place = el.style.getPropertyValue('background-position');
        entry.size = el.style.getPropertyValue('background-size');
        el.style.setProperty('background-image', 'radial-gradient(circle, ' + colour + ' 3px, transparent 3.5px)');
        el.style.setProperty('background-repeat', 'no-repeat');
        el.style.setProperty('background-position', 'right 6px center');
        el.style.setProperty('background-size', '8px 8px');
      }
      function unmark(entry) {
        if (entry.image === undefined) return;
        entry.box.style.setProperty('background-image', entry.image);
        entry.box.style.setProperty('background-repeat', entry.repeat);
        entry.box.style.setProperty('background-position', entry.place);
        entry.box.style.setProperty('background-size', entry.size);
      }
      function nextEmpty(from) {
        var at = seen.indexOf(from);
        for (var i = at + 1; i < seen.length; i++) {
          if (seen[i].isConnected && empty(seen[i]) && usable(seen[i])) return seen[i];
        }
        return null;
      }
      function undo() {
        if (!filling) return 0;
        var entries = filling;
        filling = null;
        entries.forEach(function (entry) {
          if (entry.box.isConnected) put(entry.box, entry.before);
          unmark(entry);
        });
        return entries.length;
      }

      window.__broadwayFields = {
        token: token,
        describe: function (el) {
          if (!usable(el) || kind(el) === 'password') return null;
          return describe(el, -1);
        },
        scan: function () {
          seen = candidates();
          var focused = seen.indexOf(document.activeElement);
          return { token: token, focused: focused, fields: seen.map(describe) };
        },
        apply: function (items, origin) {
          if (location.origin !== origin) return null;
          var entries = [], missed = 0;
          items.forEach(function (item) {
            var el = seen[item.index];
            if (!el || !el.isConnected || !empty(el)) { missed++; return; }
            var entry = { box: el, before: tag(el) === 'select' ? el.value : '' };
            if (!put(el, item.value)) { missed++; return; }
            mark(el, entry, item.dot);
            entries.push(entry);
          });
          if (entries.length) filling = (filling || []).concat(entries);
          if (isTop && entries.length) {
            var last = entries[entries.length - 1].box;
            var next = null;
            for (var i = 0; i < seen.length && !next; i++) {
              if (seen[i].isConnected && empty(seen[i]) && usable(seen[i])) next = seen[i];
            }
            if (next) next.focus(); else if (last.focus) last.focus();
          }
          return { filled: entries.length, missed: missed };
        },
        undo: undo,
        code: function (code, origin) {
          if (location.origin !== origin) return false;
          var el = document.activeElement;
          if (!usable(el)) return false;
          if (el.maxLength === 1) {
            var row = peers(el).filter(function (other) { return other.maxLength === 1; });
            var start = row.indexOf(el);
            if (row.length - start < code.length) return false;
            for (var i = 0; i < code.length; i++) put(row[start + i], code.charAt(i));
            return true;
          }
          return put(el, code);
        },
        holdEnter: function (on) { holdEnter = !!on; },
        holdsEnter: function () { return holdEnter && empty(document.activeElement); },
        sentStill: function () {
          return sent.some(function (el) { return el.isConnected && !empty(el) && shown(el); });
        },
        answeredStill: function () {
          return answered.some(function (el) { return el.isConnected && !empty(el) && shown(el); });
        }
      };

      var worth = /cc-|card|street|address|postal|zip/;
      var kept = /cc-name|cc-number|cc-exp|card|expir|street|address|postal|zip|city|state|region|province|country|name|phone|tel|company|organi/;
      var never = /cvc|cvv|csc|security.?code|password|\\bpin\\b|ssn|iban|one-time-code/;
      function said(el) {
        return [el.getAttribute('autocomplete'), el.getAttribute('name'), el.id, labelled(el), el.getAttribute('placeholder')]
          .join(' ').toLowerCase();
      }
      function capture(form) {
        var boxes = peers(form);
        if (!boxes.some(function (el) { return worth.test(said(el)) && !empty(el); })) return;
        var fields = [];
        sent = [];
        boxes.forEach(function (el, index) {
          var text = said(el);
          if (kind(el) === 'password' || never.test(text) || !kept.test(text) || empty(el)) return;
          var field = describe(el, index);
          field.value = el.value;
          fields.push(field);
          sent.push(el);
        });
        if (fields.length) post({ kind: 'sent', fields: fields });
      }
      function rememberable(el) {
        if (el.__broadwaySecret || empty(el) || answerKinds.indexOf(kind(el)) < 0) return false;
        if (answerRefused.test((el.getAttribute('autocomplete') || '').toLowerCase())) return false;
        var value = el.value || '';
        return value.trim().length > 0 && value.length <= 400;
      }
      function answer(form) {
        if (form.getAttribute && (form.getAttribute('autocomplete') || '').toLowerCase() === 'off') return;
        var fields = [], boxes = [];
        peers(form).forEach(function (el, index) {
          if (!rememberable(el)) return;
          var field = describe(el, index);
          field.value = el.value;
          fields.push(field);
          boxes.push(el);
        });
        if (!fields.length) return;
        answered = boxes;
        post({ kind: 'answers', fields: fields });
      }

      document.addEventListener('input', function (event) {
        if (!event.isTrusted || !filling) return;
        filling = null;
        post({ kind: 'typed' });
      }, true);
      document.addEventListener('keydown', function (event) {
        if (!event.isTrusted) return;
        var plain = !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey;
        if (filling && event.metaKey && !event.shiftKey && !event.ctrlKey && !event.altKey && (event.key === 'z' || event.key === 'Z')) {
          event.preventDefault();
          event.stopImmediatePropagation();
          undo();
          post({ kind: 'undone' });
        } else if (filling && plain && event.key === 'Tab') {
          var next = nextEmpty(document.activeElement);
          if (next) {
            event.preventDefault();
            next.focus();
          }
        } else if (plain && event.key === 'Enter' && window.__broadwayFields.holdsEnter()) {
          event.preventDefault();
          event.stopImmediatePropagation();
          post({ kind: 'enter' });
        }
      }, true);

      function snippetFocused(event) {
        var el = document.activeElement;
        while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
        if (el && (el.getAttribute('type') || '').toLowerCase() === 'password') el.__broadwaySecret = true;
        if (event && el && !/^(IFRAME|FRAME)$/.test(el.tagName)) post({ kind: 'snippetFocus' });
      }
      document.addEventListener('focusin', snippetFocused, true);
      snippetFocused();

      if (isTop) {
        document.addEventListener('submit', function (event) {
          capture(event.target);
          answer(event.target);
        }, true);
        document.addEventListener('click', function (event) {
          var el = event.target;
          if (!event.isTrusted || !el || !el.closest) return;
          var button = el.closest('button, input[type="submit"]');
          if (!button) return;
          var form = button.form || button.closest('form');
          if (!form) return;
          capture(form);
          answer(form);
        }, true);
        return;
      }

      var told = 0, posts = 0, watching = null, started = Date.now();
      function tell() {
        watching = null;
        var count = candidates().length;
        if (count === told || posts > 10) return;
        told = count;
        posts++;
        if (count) post({ kind: 'frame' });
      }
      post({ kind: 'reach' });
      tell();
      window.addEventListener('load', tell);
      new MutationObserver(function (changes, observer) {
        if (Date.now() - started > 15000) return observer.disconnect();
        if (!watching) watching = setTimeout(tell, 400);
      }).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """
}

enum FormEvent {
    case typed
    case undone
    case enter
    case sent([FormField], values: [String: String])
    case answered([FormField], values: [String: String])
}

final class FieldRelay: NSObject, WKScriptMessageHandler {
    weak var tab: Tab?
    var onEvent: ((FormEvent) -> Void)?
    private(set) var frames: [String: WKFrameInfo] = [:]
    private(set) var reach: [String: WKFrameInfo] = [:]

    func forget(_ token: String) {
        frames[token] = nil
        reach[token] = nil
    }

    func forgetAll() {
        frames = [:]
        reach = [:]
    }

    private static func read(_ body: [String: Any]) -> ([FormField], [String: String]) {
        let rows = body["fields"] as? [[String: Any]] ?? []
        let fields = rows.compactMap { FormField(page: $0) }
        var values: [String: String] = [:]
        for row in rows {
            if let index = row["index"] as? Int, let value = row["value"] as? String { values[":\(index)"] = value }
        }
        return (fields, values)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        MainActor.assumeIsolated {
            let event: FormEvent?
            switch kind {
            case "snippetFocus":
                tab?.snippetFrame = message.frameInfo.isMainFrame ? nil : message.frameInfo
                tab?.onSnippetFocus?()
                event = nil
            case "frame":
                if let token = body["token"] as? String, !message.frameInfo.isMainFrame, frames.count < 32 {
                    frames[token] = message.frameInfo
                }
                event = nil
            case "reach":
                if let token = body["token"] as? String, !message.frameInfo.isMainFrame, reach.count < 32 {
                    reach[token] = message.frameInfo
                }
                event = nil
            case "typed": event = .typed
            case "undone": event = .undone
            case "enter": event = .enter
            case "sent":
                guard message.frameInfo.isMainFrame else { return }
                let (fields, values) = Self.read(body)
                event = .sent(fields, values: values)
            case "answers":
                guard message.frameInfo.isMainFrame else { return }
                let (fields, values) = Self.read(body)
                event = .answered(fields, values: values)
            default:
                event = nil
            }
            guard let event else { return }
            onEvent?(event)
            if let tab { tab.onFormEvent?(tab, event) }
        }
    }
}

struct FormValue: Equatable {
    var fieldID: String
    var value: String
    var source: FormSource
}

enum FormSource: String {
    case profile, address, card, draft, remembered

    var dot: String {
        switch self {
        case .profile: return "#2f7df6"
        case .address: return "#20a464"
        case .card: return "#7a5af5"
        case .draft: return "#e8912d"
        case .remembered: return "#d6457f"
        }
    }

    var help: String? {
        self == .remembered ? FormMemory.help : nil
    }
}

struct FormApplied: Equatable {
    var filled = 0
    var missed = 0
}

@MainActor
protocol FormPageAccess: AnyObject {
    func fields() async -> [FormField]
    func apply(_ values: [FormValue], fields: [FormField]) async -> FormApplied
    func undo() async
}

@MainActor
final class WebFormPage: FormPageAccess {
    private let web: WKWebView
    private let relay: FieldRelay

    init(web: WKWebView, relay: FieldRelay) {
        self.web = web
        self.relay = relay
    }

    private func call(_ body: String, _ arguments: [String: Any] = [:], in frame: WKFrameInfo? = nil) async -> Result<Any?, Error> {
        await withCheckedContinuation { done in
            web.callAsyncJavaScript(body, arguments: arguments, in: frame, in: Web.world) { result in
                done.resume(returning: result.map { $0 as Any? })
            }
        }
    }

    private func origin(of url: URL?) -> String {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return "" }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    func fields() async -> [FormField] {
        var found: [FormField] = []
        if case .success(let answer) = await call("return window.__broadwayFields ? window.__broadwayFields.scan() : null") {
            found += Self.read(answer, frame: "", origin: origin(of: web.url))
        }
        for (token, info) in relay.frames {
            let frameOrigin = Self.origin(of: info.securityOrigin)
            switch await call("return window.__broadwayFields ? window.__broadwayFields.scan() : null", in: info) {
            case .success(let answer): found += Self.read(answer, frame: token, origin: frameOrigin)
            case .failure: relay.forget(token)
            }
        }
        return found
    }

    private static func origin(of security: WKSecurityOrigin) -> String {
        "\(security.protocol)://\(security.host)" + (security.port == 0 ? "" : ":\(security.port)")
    }

    private static func read(_ answer: Any?, frame: String, origin: String) -> [FormField] {
        guard let scan = answer as? [String: Any], let rows = scan["fields"] as? [[String: Any]] else { return [] }
        let focused = scan["focused"] as? Int
        return rows.compactMap { FormField(page: $0, frame: frame, origin: origin, focused: focused) }
    }

    func apply(_ values: [FormValue], fields: [FormField]) async -> FormApplied {
        let known = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0) })
        var byFrame: [String: [[String: Any]]] = [:]
        var origins: [String: String] = [:]
        var applied = FormApplied()
        for value in values {
            guard let field = known[value.fieldID] else {
                applied.missed += 1
                continue
            }
            byFrame[field.frame, default: []].append(["index": field.index, "value": value.value, "dot": value.source.dot])
            origins[field.frame] = field.origin
        }
        for (frame, items) in byFrame {
            guard frame.isEmpty || relay.frames[frame] != nil else {
                applied.missed += items.count
                continue
            }
            let info = frame.isEmpty ? nil : relay.frames[frame]
            let answer = await call("return window.__broadwayFields ? window.__broadwayFields.apply(items, origin) : null",
                                    ["items": items, "origin": origins[frame] ?? ""], in: info)
            guard case .success(let reply) = answer, let reply = reply as? [String: Any] else {
                applied.missed += items.count
                continue
            }
            applied.filled += reply["filled"] as? Int ?? 0
            applied.missed += reply["missed"] as? Int ?? 0
        }
        return applied
    }

    func undo() async {
        _ = await call("return window.__broadwayFields ? window.__broadwayFields.undo() : 0")
        for (_, info) in relay.frames {
            _ = await call("return window.__broadwayFields ? window.__broadwayFields.undo() : 0", in: info)
        }
    }

    func put(code: String, origin expected: String) async -> Bool {
        let answer = await call("return window.__broadwayFields ? window.__broadwayFields.code(code, origin) : false", ["code": code, "origin": expected])
        if case .success(let reply) = answer { return reply as? Bool ?? false }
        return false
    }

    func holdEnter(_ on: Bool) {
        web.evaluateInSearch("window.__broadwayFields && window.__broadwayFields.holdEnter(\(on))")
    }

    func sentStill() async -> Bool {
        if case .success(let reply) = await call("return window.__broadwayFields ? window.__broadwayFields.sentStill() : false") {
            return reply as? Bool ?? false
        }
        return false
    }

    func answeredStill() async -> Bool {
        if case .success(let reply) = await call("return window.__broadwayFields ? window.__broadwayFields.answeredStill() : false") {
            return reply as? Bool ?? false
        }
        return false
    }
}
