import AppKit
import NaturalLanguage
import Translation
import WebKit

struct TranslationMark: Equatable {
    enum Phase: Equatable {
        case working
        case done
        case failed(String)
    }
    var from: String?
    var to: String
    var phase: Phase

    var failed: Bool { if case .failed = phase { return true } else { return false } }
}

@MainActor
final class PageTranslator {
    static let key = "translate.pages"
    static let alwaysKey = "translate.always"

    static var fake: Bool { Store.testing && ProcessInfo.processInfo.environment["SEARCH_TRANSLATE_FAKE"] != nil }

    nonisolated static var reader: Locale.Language {
        PreferredLanguages.reader(PreferredLanguages.settings)
    }

    static func reader(for tab: Tab?) -> Locale.Language {
        tab.map { PreferredLanguages.reader($0.languages) } ?? reader
    }

    nonisolated static func name(_ code: String) -> String {
        let english = Locale(identifier: "en")
        let language = Locale.Language(identifier: code)
        if language.script != nil, let full = english.localizedString(forIdentifier: code) { return full }
        return english.localizedString(forLanguageCode: language.languageCode?.identifier ?? code) ?? code
    }

    nonisolated static func code(_ language: Locale.Language) -> String {
        let base = language.languageCode?.identifier ?? language.minimalIdentifier
        if let script = language.script?.identifier, base == "zh" || base == "sr" { return "\(base)-\(script)" }
        return base
    }

    nonisolated static func same(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        guard a.languageCode == b.languageCode else { return false }
        guard let x = a.script, let y = b.script else { return true }
        return x == y
    }

    private weak var tab: Tab?
    private weak var web: WKWebView?
    let target: Locale.Language
    private(set) var source: Locale.Language?
    private var task: Task<Void, Never>?
    private var jobs: AsyncStream<WKFrameInfo?>.Continuation?
    private var frames: [WKFrameInfo] = []
    private var sessions: [String: Translate?] = [:]
    private var leases: [AnyObject] = []
    private var cache: [String: String] = [:]
    private(set) var report: [String: Any] = [:]
    private var done: (([String: Any]) -> Void)?

    private init(tab: Tab, target: Locale.Language) {
        self.tab = tab
        self.web = tab.built
        self.target = target
    }

    @discardableResult
    static func start(_ tab: Tab, to asked: Locale.Language? = nil, done: (([String: Any]) -> Void)? = nil) -> PageTranslator? {
        let target = asked ?? reader(for: tab)
        tab.translator?.end(restore: true)
        guard tab.built != nil else {
            done?(["error": "no page"])
            return nil
        }
        let translator = PageTranslator(tab: tab, target: target)
        translator.done = done
        tab.translator = translator
        tab.translation = TranslationMark(from: nil, to: code(target), phase: .working)
        let (stream, continuation) = AsyncStream<WKFrameInfo?>.makeStream()
        translator.jobs = continuation
        translator.task = Task { @MainActor in
            await translator.run(stream)
        }
        return translator
    }

    func end(restore: Bool) {
        task?.cancel()
        jobs?.finish()
        jobs = nil
        for lease in leases { (lease as? Closable)?.close() }
        leases = []
        if let tab, tab.translator === self {
            tab.translator = nil
            if tab.translation?.failed != true { tab.translation = nil }
        }
        if restore, let web {
            let frames = self.frames
            Task { @MainActor in
                for frame in [nil] + frames.map(Optional.some) {
                    _ = try? await web.callAsyncJavaScript(PageTranslator.restoreCall, in: frame, contentWorld: Web.world)
                }
            }
        }
        finish()
    }

    func changed(in frame: WKFrameInfo?) { jobs?.yield(frame) }

    func arrived(_ frame: WKFrameInfo) { jobs?.yield(frame) }

    private func finish() {
        if let done {
            self.done = nil
            done(report)
        }
    }

    private func run(_ stream: AsyncStream<WKFrameInfo?>) async {
        guard let web, let tab else { return }
        let start = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        report = ["target": PageTranslator.code(target), "units": 0, "parts": 0, "requests": 0, "sent": 0,
                  "cached": 0, "applied": 0, "kept": 0, "chars": 0, "frames": 0, "rounds": 0, "languages": [String: Int]()]
        do {
            let first = try await collect(nil, injecting: true)
            report["collectMs"] = ms()
            let hint = try? await web.callAsyncJavaScript("return document.documentElement.lang || ''", contentWorld: Web.world) as? String
            let sample = String(first.prefix(400).map(\.plain).joined(separator: "\n").prefix(4000))
            guard let from = PageTranslator.detect(sample, hint: hint) else {
                throw Failure("Broadway couldn't tell which language this page is in")
            }
            source = from
            report["source"] = PageTranslator.code(from)
            tab.translation = TranslationMark(from: PageTranslator.code(from), to: PageTranslator.code(target), phase: .working)
            if !PageTranslator.same(from, target) {
                sessions[PageTranslator.code(from)] = try await session(from: from, main: true)
            }
            try await process(first, in: nil) { self.report["firstSliceMs"] = self.report["firstSliceMs"] ?? ms() }
            for frame in tab.translateFrames {
                try await frameRound(frame)
            }
            report["fullMs"] = ms()
            if (report["applied"] as? Int ?? 0) == 0, PageTranslator.same(from, target) {
                throw Failure("This page is already in \(PageTranslator.name(PageTranslator.code(target)))")
            }
            tab.translation?.phase = .done
            finish()
            for await frame in stream {
                if Task.isCancelled { break }
                if let frame { try await frameRound(frame) } else { try await process(collect(nil), in: nil) }
                report["rounds"] = (report["rounds"] as? Int ?? 0) + 1
            }
        } catch is CancellationError {
        } catch {
            guard tab.translator === self, !Task.isCancelled else { return }
            let message = (error as? Failure)?.message ?? PageTranslator.describe(error, from: source, to: target)
            report["error"] = message
            report["errorDetail"] = "\(error)"
            tab.failTranslation(TranslationMark(from: source.map(PageTranslator.code), to: PageTranslator.code(target), phase: .failed(message)))
            end(restore: true)
        }
    }

    private func frameRound(_ frame: WKFrameInfo) async throws {
        let units: [Unit]
        do {
            units = try await collect(frame, injecting: true)
        } catch {
            tab?.translateFrames.removeAll { $0 === frame }
            return
        }
        if !frames.contains(where: { $0 === frame }) {
            frames.append(frame)
            report["frames"] = frames.count
        }
        try await process(units, in: frame)
    }

    struct Unit {
        let id: Int
        let parts: [String]
        let gaps: [Bool]
        let fixed: [Bool]
        var plain: String {
            var out = ""
            for (index, part) in parts.enumerated() { out += (index > 0 && gaps[index] ? " " : "") + part }
            return out
        }
    }

    private func collect(_ frame: WKFrameInfo?, injecting: Bool = false) async throws -> [Unit] {
        guard let web else { return [] }
        let call = (injecting ? PageTranslator.script + ";\n" : "") + "return window.__searchTr ? __searchTr.collect() : []"
        let raw = try await web.callAsyncJavaScript(call, in: frame, contentWorld: Web.world) as? [Any] ?? []
        return raw.compactMap { item in
            guard let row = item as? [Any], row.count == 4, let id = (row[0] as? NSNumber)?.intValue,
                  let parts = row[1] as? [String], let gaps = row[2] as? [Any], let fixed = row[3] as? [Any],
                  gaps.count == parts.count, fixed.count == parts.count, !parts.isEmpty else { return nil }
            return Unit(id: id, parts: parts, gaps: gaps.map { ($0 as? NSNumber)?.boolValue ?? false },
                        fixed: fixed.map { ($0 as? NSNumber)?.boolValue ?? false })
        }
    }

    private func process(_ units: [Unit], in frame: WKFrameInfo?, first: (() -> Void)? = nil) async throws {
        guard !units.isEmpty, let web else { return }
        report["units"] = (report["units"] as? Int ?? 0) + units.count
        report["parts"] = (report["parts"] as? Int ?? 0) + units.reduce(0) { $0 + $1.parts.count }
        report["chars"] = (report["chars"] as? Int ?? 0) + units.reduce(0) { $0 + $1.plain.count }
        var index = 0
        var size = 24
        while index < units.count {
            try Task.checkCancellation()
            var slice: [Unit] = []
            var chars = 0
            while index < units.count, slice.count < size, chars < (size > 24 ? 12000 : 3000) {
                slice.append(units[index]); chars += units[index].plain.count; index += 1
            }
            size = 160
            let page = source.map(PageTranslator.code) ?? PageTranslator.code(target)
            let texts = slice.map(\.plain)
            let languages = await Task.detached(priority: .userInitiated) {
                PageTranslator.languages(of: texts, page: page)
            }.value
            try Task.checkCancellation()
            var out: [Int: [String]?] = [:]
            var counts = report["languages"] as? [String: Int] ?? [:]
            for language in Set(languages) {
                let group = slice.indices.filter { languages[$0] == language }.map { slice[$0] }
                counts[language, default: 0] += group.count
                guard let translate = try await translator(for: language) else {
                    for unit in group { out[unit.id] = .some(nil) }
                    report["kept"] = (report["kept"] as? Int ?? 0) + group.count
                    continue
                }
                let done = try await translateUnits(group, language: language, with: translate)
                for (unit, parts) in zip(group, done) { out[unit.id] = .some(parts) }
            }
            report["languages"] = counts
            let pairs: [[Any]] = slice.map { unit in
                [NSNumber(value: unit.id), (out[unit.id] ?? nil).map { $0 as Any } ?? NSNull()]
            }
            let applied = try await web.callAsyncJavaScript("return window.__searchTr ? __searchTr.apply(pairs) : 0",
                                                            arguments: ["pairs": pairs], in: frame, contentWorld: Web.world)
            report["applied"] = (report["applied"] as? Int ?? 0) + ((applied as? NSNumber)?.intValue ?? 0)
            first?()
        }
    }

    private func translator(for code: String) async throws -> Translate? {
        let language = Locale.Language(identifier: code)
        if PageTranslator.same(language, target) { return nil }
        if let known = sessions[code] { return known }
        let made = try? await session(from: language, main: false)
        sessions[code] = .some(made)
        return made
    }

    private func translateUnits(_ units: [Unit], language: String, with translate: Translate) async throws -> [[String]] {
        var wanted: [String] = []
        var joined: [Int: String] = [:]
        for (index, unit) in units.enumerated() {
            if unit.parts.count > 1, let line = PageTranslator.joined(unit.parts, gaps: unit.gaps) {
                joined[index] = line
                wanted.append(line)
            } else {
                for (part, fixed) in zip(unit.parts, unit.fixed) where !fixed { wanted.append(part) }
            }
        }
        var got = try await strings(wanted, language: language, with: translate)
        var results: [[String]?] = Array(repeating: nil, count: units.count)
        var again: [Int] = []
        for (index, unit) in units.enumerated() {
            if let line = joined[index] {
                if let back = got[line], let pieces = PageTranslator.split(back, count: unit.parts.count),
                   zip(pieces, zip(unit.parts, unit.fixed)).allSatisfy({ piece, part in part.1 || !PageTranslator.letters(part.0) || !piece.isEmpty }) {
                    results[index] = pieces
                } else {
                    again.append(index)
                }
            }
        }
        if !again.isEmpty {
            report["unjoined"] = (report["unjoined"] as? Int ?? 0) + again.count
            let pieces = again.flatMap { index in zip(units[index].parts, units[index].fixed).filter { !$0.1 }.map(\.0) }
            got.merge(try await strings(pieces, language: language, with: translate)) { $1 }
        }
        for (index, unit) in units.enumerated() where results[index] == nil {
            results[index] = zip(unit.parts, unit.fixed).map { part, fixed in fixed ? part : (got[part] ?? part) }
        }
        return results.map { $0 ?? [] }
    }

    private func strings(_ texts: [String], language: String, with translate: Translate) async throws -> [String: String] {
        var out: [String: String] = [:]
        var missing: [String] = []
        var seen = Set<String>()
        for text in texts {
            if let known = cache[language + "\u{1}" + text] {
                out[text] = known
                report["cached"] = (report["cached"] as? Int ?? 0) + 1
            } else if seen.insert(text).inserted {
                missing.append(text)
            } else {
                report["cached"] = (report["cached"] as? Int ?? 0) + 1
            }
        }
        guard !missing.isEmpty else { return out }
        report["requests"] = (report["requests"] as? Int ?? 0) + 1
        report["sent"] = (report["sent"] as? Int ?? 0) + missing.count
        let back = try await translate(missing)
        for (text, translated) in zip(missing, back) {
            cache[language + "\u{1}" + text] = translated
            out[text] = translated
        }
        return out
    }

    nonisolated static func mark(_ index: Int) -> String { "[\(index)]" }
    nonisolated private static let marks = try! NSRegularExpression(pattern: #"\[\d+\]"#)

    nonisolated static func letters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    nonisolated static func joined(_ parts: [String], gaps: [Bool]) -> String? {
        var out = ""
        for (index, part) in parts.enumerated() {
            let range = NSRange(part.startIndex..., in: part)
            if marks.firstMatch(in: part, range: range) != nil { return nil }
            if index > 0 { out += (gaps[index] ? " " : "") + mark(index) }
            out += part
        }
        return out
    }

    nonisolated static func split(_ text: String, count: Int) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        let found = marks.matches(in: text, range: range)
        guard found.count == count - 1 else { return nil }
        var pieces: [String] = []
        var rest = text[...]
        for index in 1..<count {
            guard let at = rest.range(of: mark(index)) else { return nil }
            pieces.append(String(rest[..<at.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[at.upperBound...]
        }
        pieces.append(String(rest).trimmingCharacters(in: .whitespacesAndNewlines))
        return pieces
    }

    nonisolated static func detect(_ text: String, hint: String?) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let best = recognizer.languageHypotheses(withMaximum: 1).first
        if let best, best.key != .undetermined, best.value >= 0.5 || hint?.isEmpty != false {
            return Locale.Language(identifier: best.key.rawValue)
        }
        if let hint, !hint.isEmpty { return Locale.Language(identifier: hint) }
        return nil
    }

    nonisolated static func languages(of texts: [String], page: String) -> [String] {
        let recognizer = NLLanguageRecognizer()
        return texts.map { text in
            guard text.count >= 40 else { return page }
            recognizer.reset()
            recognizer.processString(text)
            guard let best = recognizer.languageHypotheses(withMaximum: 1).first,
                  best.key != .undetermined, best.value >= 0.8 else { return page }
            return code(Locale.Language(identifier: best.key.rawValue))
        }
    }

    typealias Translate = ([String]) async throws -> [String]

    private func session(from: Locale.Language, main: Bool) async throws -> Translate? {
        if PageTranslator.fake {
            let tag = "[\(PageTranslator.code(from))→\(PageTranslator.code(target))] "
            return { strings in strings.map { tag + $0 } }
        }
        let status = await LanguageAvailability().status(from: from, to: target)
        if main { report["availability"] = "\(status)" }
        switch status {
        case .unsupported:
            if main {
                throw Failure("\(PageTranslator.name(PageTranslator.code(from))) to \(PageTranslator.name(PageTranslator.code(target))) can't be translated on this Mac")
            }
            return nil
        case .installed:
            let session = TranslationSession(installedSource: from, target: target)
            return { strings in try await PageTranslator.translate(strings, with: session) }
        default:
            if !main { return nil }
        }
        guard let content = web?.window?.contentView else { throw Failure("Translate Page needs the tab in a window") }
        let lease = try await SessionLease.open(from: from, to: target, in: content)
        leases.append(lease)
        let session: TranslationSession = lease.session
        return { strings in try await PageTranslator.translate(strings, with: session) }
    }

    private static func translate(_ strings: [String], with session: TranslationSession) async throws -> [String] {
        let requests = strings.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        var out = strings
        for response in try await session.translations(from: requests) {
            if let index = response.clientIdentifier.flatMap(Int.init), out.indices.contains(index) { out[index] = response.targetText }
        }
        return out
    }

    private static func describe(_ error: Error, from: Locale.Language?, to: Locale.Language) -> String {
        let language = from.map { name(code($0)) } ?? "this page's language"
        if let error = error as? TranslationError {
            switch error {
            case .unsupportedLanguagePairing, .unsupportedSourceLanguage, .unsupportedTargetLanguage:
                return "\(language) to \(name(code(to))) can't be translated on this Mac"
            case .unableToIdentifyLanguage:
                return "Broadway couldn't tell which language this page is in"
            default:
                break
            }
        }
        return "\(language) wasn't translated. You may still need to download it in System Settings › General › Language & Region › Translation Languages."
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static let restoreCall = "return window.__searchTr ? __searchTr.restore() : 0"

    static let script = #"""
    if (!window.__searchTr) (function () {
      // Left as they are, with everything in them.
      var SKIP = { script:1, style:1, noscript:1, textarea:1, input:1, select:1, option:1, code:1, pre:1,
                   kbd:1, samp:1, 'var':1, svg:1, math:1, canvas:1, template:1, iframe:1, frame:1,
                   object:1, embed:1, video:1, audio:1, head:1 };
      // Inline: a sentence goes on through them.
      var INLINE = { a:1, abbr:1, b:1, bdi:1, bdo:1, big:1, cite:1, data:1, del:1, dfn:1, em:1, font:1,
                     i:1, ins:1, label:1, mark:1, nobr:1, q:1, s:1, small:1, span:1, strike:1, strong:1,
                     sub:1, sup:1, time:1, tt:1, u:1, img:1, wbr:1, code:1, kbd:1, samp:1, 'var':1 };
      // Read as part of the sentence around them, never written.
      var FIXED = { code:1, kbd:1, samp:1, 'var':1 };
      var ATTRS = ['title', 'alt', 'placeholder', 'aria-label'];
      var LETTER = /\p{L}/u, SPACE = /\S/;
      var texts = new Map();      // text node -> { orig, ours, sent, kept }
      var attrs = new Map();      // element -> { name: the same }
      var units = [];             // id -> { targets }
      var watched = [], touched = [], whole = true;
      var applying = false, timer = 0;
      var run = null, out = null;

      function post(m) { try { webkit.messageHandlers.officeTranslate.postMessage(m); } catch (e) {} }
      function pending(rec, v) { return rec.ours !== v && rec.sent !== v && rec.kept !== v; }
      function closed(el) {
        if (el.getAttribute('translate') === 'no') return true;
        if (el.classList && el.classList.contains('notranslate')) return true;
        var c = el.getAttribute('contenteditable');
        return c !== null && c !== 'false';
      }
      function blockOf(n) {
        var el = n.parentNode;
        while (el && el.nodeType === 1 && INLINE[el.localName]) el = el.parentNode;
        return el;
      }
      function close() {
        if (run && run.targets.some(function (t) { return !t.fixed; })) {
          var id = units.length;
          units.push({ targets: run.targets });
          out.push({ id: id, parts: run.parts, gaps: run.gaps, fixed: run.targets.map(function (t) { return !!t.fixed; }), at: run.at });
        }
        run = null;
      }
      function part(text, target, at, block, lead) {
        if (run && (run.block !== block || run.parts.length >= 16 || run.chars + text.length > 1500)) close();
        if (!run) run = { block: block, parts: [], gaps: [], targets: [], chars: 0, space: false, at: at };
        run.gaps.push(run.parts.length > 0 && (run.space || lead));
        run.parts.push(text.trim());
        run.targets.push(target);
        run.chars += text.length;
        run.space = /\s$/.test(text);
      }
      function fixedPart(el) {
        var t = el.textContent;
        if (!SPACE.test(t)) { if (run) run.space = true; return; }
        part(t, { fixed: true }, el, blockOf(el), /^\s/.test(t));
      }
      function attributes(el) {
        var name = el.localName;
        for (var i = 0; i < ATTRS.length; i++) {
          var a = ATTRS[i];
          if (a === 'alt' && name !== 'img' && name !== 'area' && name !== 'input') continue;
          if (a === 'placeholder' && name !== 'input' && name !== 'textarea') continue;
          var v = el.getAttribute(a);
          if (!v || !LETTER.test(v)) continue;
          var map = attrs.get(el);
          if (!map) { map = {}; attrs.set(el, map); }
          var rec = map[a];
          if (rec && !pending(rec, v)) continue;
          if (!rec) { rec = map[a] = { orig: v }; } else if (rec.ours !== v) { rec.orig = v; rec.ours = null; }
          rec.kept = null; rec.sent = v;
          var id = units.length;
          units.push({ targets: [{ el: el, attr: a, rec: rec }] });
          out.push({ id: id, parts: [v.trim()], gaps: [false], fixed: [false], at: el });
        }
      }
      // An element as the walk meets it: what it says about the sentence
      // being read, and whether to go into it.
      function element(el) {
        var name = el.localName;
        if (name === 'br') { close(); return NodeFilter.FILTER_SKIP; }
        if (closed(el)) {
          if (INLINE[name]) fixedPart(el); else close();
          return NodeFilter.FILTER_REJECT;
        }
        if (el.hasAttribute('title') || el.hasAttribute('alt') || el.hasAttribute('placeholder') || el.hasAttribute('aria-label')) attributes(el);
        if (SKIP[name]) {
          if (FIXED[name]) fixedPart(el); else close();
          return NodeFilter.FILTER_REJECT;
        }
        if (el.shadowRoot) { close(); watch(el.shadowRoot); walk(el.shadowRoot); close(); }
        if (!INLINE[name]) close();
        return NodeFilter.FILTER_SKIP;
      }
      function text(n) {
        var v = n.nodeValue;
        if (!v || !SPACE.test(v)) { if (run) run.space = true; return; }
        var block = blockOf(n);
        if (!LETTER.test(v)) { part(v, { fixed: true }, n.parentNode, block, /^\s/.test(v)); return; }
        var rec = texts.get(n);
        if (rec && !pending(rec, v)) { close(); return; }
        if (!rec) { rec = { orig: v }; texts.set(n, rec); }
        else if (rec.ours !== v) { rec.orig = v; rec.ours = null; }
        rec.kept = null; rec.sent = v;
        part(v, { node: n, rec: rec }, n.parentNode, block, /^\s/.test(v));
      }
      function walk(root) {
        var doc = root.ownerDocument || root;
        var w = doc.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
          acceptNode: function (n) { return n.nodeType === 1 ? element(n) : NodeFilter.FILTER_ACCEPT; }
        });
        for (var n = w.nextNode(); n; n = w.nextNode()) if (n.nodeType === 3) text(n);
        close();
      }
      // Whether something changed is somewhere the walk goes.
      function open(el) {
        for (var e = el; e; ) {
          if (e.nodeType === 11) { e = e.host; continue; }
          if (e.nodeType !== 1) { e = e.parentNode; continue; }
          if (SKIP[e.localName] || closed(e)) return false;
          e = e.parentNode;
        }
        return true;
      }
      function top(el) {
        if (!el || !el.getBoundingClientRect) return 1e9;
        var r = el.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) return 1e8;
        return r.bottom < 0 ? 1e7 - r.bottom : r.top;
      }
      function changed(node) {
        if (!whole) touched.push(node);
        if (touched.length > 200) { whole = true; touched = []; }
        if (!timer) timer = setTimeout(function () { timer = 0; post({ dirty: 1 }); }, 300);
      }
      var observer = new MutationObserver(function (records) {
        if (applying) return;
        for (var i = 0; i < records.length; i++) {
          var r = records[i], t = r.target;
          if (r.type === 'characterData') {
            var k = texts.get(t);
            if (k && (k.ours === t.nodeValue || k.sent === t.nodeValue)) continue;
            changed(t.parentNode);
          } else if (r.type === 'attributes') {
            var m = attrs.get(t), rec = m && m[r.attributeName];
            if (rec && (rec.ours === t.getAttribute(r.attributeName) || rec.sent === t.getAttribute(r.attributeName))) continue;
            changed(t);
          } else {
            var real = false;
            for (var j = 0; j < r.addedNodes.length; j++) {
              var a = r.addedNodes[j];
              if (a.nodeType === 1 || (a.nodeType === 3 && LETTER.test(a.nodeValue))) { real = true; break; }
            }
            if (real) changed(t);
          }
        }
      });
      function watch(root) {
        if (watched.indexOf(root) >= 0) return;
        watched.push(root);
        observer.observe(root, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ATTRS });
      }
      window.__searchTr = {
        // Every unit not yet sent: [id, parts, gaps, fixed], on screen first.
        collect: function () {
          if (document.designMode === 'on') return [];
          out = [];
          watch(document);
          var title = window === window.top && document.querySelector('title');
          if (title && title.firstChild && title.firstChild.nodeType === 3 && LETTER.test(title.textContent)) {
            text(title.firstChild); close();
          }
          var roots = whole ? [document.body || document.documentElement] : touched;
          whole = false; touched = [];
          var seen = [];
          for (var i = 0; i < roots.length; i++) {
            var root = roots[i];
            if (!root || !root.isConnected || seen.some(function (s) { return s.contains(root); })) continue;
            if (root.nodeType === 1 && root !== document.body && !open(root)) continue;
            seen.push(root);
            if (root.nodeType === 1 && root !== document.body && root !== document.documentElement) {
              if (element(root) !== NodeFilter.FILTER_SKIP) { close(); continue; }
            }
            walk(root);
          }
          if (texts.size > 20000) texts.forEach(function (rec, node) { if (!node.isConnected) texts.delete(node); });
          var list = out; out = null;
          var tops = list.map(function (u) { return top(u.at && u.at.nodeType === 1 ? u.at : u.at && u.at.parentElement); });
          var order = list.map(function (u, i) { return i; }).sort(function (a, b) { return tops[a] - tops[b] || a - b; });
          return order.map(function (i) { var u = list[i]; return [u.id, u.parts, u.gaps, u.fixed]; });
        },
        // [id, parts or null]: each part back in its own node; null keeps
        // the unit as it is (already in your language, or can't be done).
        apply: function (pairs) {
          applying = true;
          var n = 0;
          for (var i = 0; i < pairs.length; i++) {
            var u = units[pairs[i][0]], parts = pairs[i][1];
            if (!u) continue;
            units[pairs[i][0]] = null;
            for (var j = 0; j < u.targets.length; j++) {
              var t = u.targets[j];
              if (t.fixed) continue;
              var cur = t.node ? t.node.nodeValue : t.el.getAttribute(t.attr);
              if (cur !== t.rec.sent) continue;          // changed meanwhile: the next round has it
              t.rec.sent = null;
              var p = parts && parts[j];
              if (p == null || !SPACE.test(p)) { t.rec.kept = cur; continue; }
              var o = t.rec.orig, v = o.match(/^\s*/)[0] + p.trim() + o.match(/\s*$/)[0];
              t.rec.ours = v;
              if (t.node) t.node.nodeValue = v; else t.el.setAttribute(t.attr, v);
              n++;
            }
          }
          observer.takeRecords();
          applying = false;
          return n;
        },
        // Show Original: each value back exactly as it was, where the page
        // hasn't put something else there since.
        restore: function () {
          observer.disconnect();
          clearTimeout(timer);
          var n = 0;
          texts.forEach(function (rec, node) { if (rec.ours != null && node.nodeValue === rec.ours) { node.nodeValue = rec.orig; n++; } });
          attrs.forEach(function (map, el) {
            for (var a in map) { var rec = map[a]; if (rec.ours != null && el.getAttribute(a) === rec.ours) { el.setAttribute(a, rec.orig); n++; } }
          });
          delete window.__searchTr;
          return n;
        }
      };
    })();
    """#

    static let announce = """
    if (window !== window.top) try { webkit.messageHandlers.officeTranslate.postMessage({ frame: 1 }); } catch (e) {}
    """
}

@MainActor
private protocol Closable: AnyObject { func close() }

@MainActor
private final class SessionLease: Closable {
    private(set) var session: TranslationSession!
    private var host: NSView?
    private var hold: CheckedContinuation<Void, Never>?
    private var closed = false

    static func open(from: Locale.Language, to: Locale.Language, in content: NSView) async throws -> SessionLease {
        let lease = SessionLease()
        let session: TranslationSession = await withCheckedContinuation { got in
            var given = false
            let view = TranslationHost.view(configuration: .init(source: from, target: to)) { session in
                guard !given else { return }
                given = true
                got.resume(returning: session)
                await withCheckedContinuation { (hold: CheckedContinuation<Void, Never>) in
                    if lease.closed { hold.resume() } else { lease.hold = hold }
                }
            }
            view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            view.alphaValue = 0.01
            content.addSubview(view)
            lease.host = view
        }
        lease.session = session
        return lease
    }

    func close() {
        closed = true
        hold?.resume()
        hold = nil
        host?.removeFromSuperview()
        host = nil
    }
}

final class TranslateRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeTranslate"
    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let said = message.body as? [String: Any] else { return }
        let frame = message.frameInfo
        MainActor.assumeIsolated {
            guard let tab, let web = tab.built, web === message.webView else { return }
            if said["frame"] != nil, !frame.isMainFrame {
                tab.translateFrames.append(frame)
                if tab.translateFrames.count > 64 { tab.translateFrames.removeFirst() }
                tab.translator?.arrived(frame)
            } else if said["dirty"] != nil {
                tab.translator?.changed(in: frame.isMainFrame ? nil : frame)
            }
        }
    }
}

extension Tab {
    func toggleTranslation() {
        if let translator, translation?.failed != true {
            translator.end(restore: true)
        } else {
            PageTranslator.start(self)
        }
    }

    func translationGone(sleeping: Bool) {
        if sleeping, let translator, let url = pageAddress {
            translateOnWake = (url, PageTranslator.code(translator.target))
        }
        translator?.end(restore: false)
        translation = nil
        translateFrames = []
    }

    func failTranslation(_ mark: TranslationMark) {
        translation = mark
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.translation == mark { self?.translation = nil }
        }
    }

    func alwaysTranslates(_ code: String) -> Bool {
        shy ? !translateLanguagesOff.contains(code) && (translateLanguages.contains(code) || Shared.prefs.translateAlways.contains(code))
            : Shared.prefs.translateAlways.contains(code)
    }

    func setAlwaysTranslates(_ code: String, _ on: Bool) {
        if shy {
            if on {
                translateLanguages.insert(code)
                translateLanguagesOff.remove(code)
            } else {
                translateLanguages.remove(code)
                translateLanguagesOff.insert(code)
            }
        } else {
            if on { Shared.prefs.translateAlways.insert(code) } else { Shared.prefs.translateAlways.remove(code) }
        }
    }

    func translateIfWanted() {
        guard translator == nil, let web = built, let url = pageAddress,
              ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return }
        if let wake = translateOnWake {
            translateOnWake = nil
            if wake.url == url {
                PageTranslator.start(self, to: Locale.Language(identifier: wake.to))
                return
            }
        }
        let wanted = shy ? Shared.prefs.translateAlways.union(translateLanguages).subtracting(translateLanguagesOff) : Shared.prefs.translateAlways
        guard !wanted.isEmpty else { return }
        web.callAsyncJavaScript(
            "return [document.documentElement.lang || '', document.body ? document.body.innerText.slice(0, 3000) : '']",
            in: nil, in: Web.world
        ) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.translator == nil, self.built === web,
                      let pair = (try? result.get()) as? [String], pair.count == 2,
                      let language = PageTranslator.detect(pair[1], hint: pair[0]),
                      !PreferredLanguages.reads(language, in: self.languages),
                      wanted.contains(PageTranslator.code(language)) else { return }
                PageTranslator.start(self)
            }
        }
    }
}

final class TranslateSignView: SignView {
    init(tab: Tab) {
        super.init(tab: tab, symbol: "translate", label: "Translated")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func refresh() {
        if let mark = tab?.translation {
            symbol.name = mark.failed ? "exclamationmark.bubble" : "translate"
            rest = mark.phase == .working ? 0.4 : 0.75
            let heading = TranslateMenu.heading(mark)
            kitAccess(label: heading, help: heading)
        }
        super.refresh()
    }

    override func menu(done: @escaping () -> Void) -> SignMenu? {
        guard let tab else { return nil }
        return TranslateMenu(tab: tab, done: done)
    }
}

final class TranslateMenu: SignMenu {
    let tab: Tab
    let done: () -> Void

    static func heading(_ mark: TranslationMark) -> String {
        let from = mark.from.map(PageTranslator.name)
        switch mark.phase {
        case .working: return from.map { "Translating from \($0)…" } ?? "Translating…"
        case .done: return from.map { "Translated from \($0)" } ?? "Translated"
        case .failed(let message): return message
        }
    }

    init(tab: Tab, done: @escaping () -> Void) {
        self.tab = tab
        self.done = done
        super.init()
        follows = true
        rebuild()
    }

    override func parts() -> [SignMenu.Part] {
        let mark = tab.translation ?? TranslationMark(from: nil, to: "en", phase: .done)
        var out: [SignMenu.Part] = [.heading(TranslateMenu.heading(mark))]
        guard !mark.failed else { return out }
        var entries = [SignMenu.Entry(symbol: "arrow.uturn.backward", title: "Show Original") { [weak self] in
            self?.tab.translator?.end(restore: true)
            self?.done()
        }]
        if let from = mark.from {
            let on = tab.alwaysTranslates(from)
            entries.append(SignMenu.Entry(
                symbol: "checkmark",
                title: tab.shy ? "Translate \(PageTranslator.name(from)) in This Tab" : "Always Translate \(PageTranslator.name(from))",
                on: on,
                help: tab.shy ? "Only in this tab" : "Choose it again to stop"
            ) { [weak self] in
                self?.tab.setAlwaysTranslates(from, !on)
                self?.rebuild()
            })
        }
        out.append(.items(entries))
        out.append(.divider)
        out.append(.footnote("Translated on this Mac. Nothing is sent anywhere."))
        return out
    }
}
