import AppKit
import WebKit

enum SnippetPage {
    static let helpers = """
    \(PageSelection.secretCheck)
    function snippetElement() {
      var el = document.activeElement;
      while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
      return el;
    }
    function snippetSecret(el) {
      for (var node = el; node; node = node.parentElement || (node.getRootNode && node.getRootNode().host)) {
        if (broadwaySecret(node)) return true;
        var words = [node.getAttribute('name'), node.id, node.getAttribute('aria-label'), node.getAttribute('placeholder'), node.getAttribute('title')].join(' ');
        if (node === el && el.labels) words += ' ' + Array.from(el.labels).map(function (label) { return label.textContent; }).join(' ');
        var labelled = (node.getAttribute('aria-labelledby') || '').split(/\\s+/);
        var root = node.getRootNode ? node.getRootNode() : document;
        words += ' ' + labelled.map(function (id) { var label = root.getElementById ? root.getElementById(id) : null; return label ? label.textContent : ''; }).join(' ');
        if (/card.?(num|no)|cardnumber|cc.?num|\\bcvc\\b|\\bcvv\\b|security.?code|pass.?word|passwd|\\bpwd\\b|passcode|passphrase|\\bpin\\b|\\bssn\\b|social.?security|api.?key|\\btoken\\b|\\bsecret\\b|\\botp\\b|one.?time|verification.?code|\\biban\\b|routing.?number|парол|секрет|токен|код.?доступ|номер[\\s_-]*(?:банковск[а-яё]*[\\s_-]*)?карт|код[\\s_-]*подтвержден|одноразов[а-яё]*[\\s_-]*код/i.test(words)) return true;
      }
      return false;
    }
    function snippetStatus(el) {
      if (!el) return 'none';
      if (snippetSecret(el)) return 'blocked';
      if (/^(IFRAME|FRAME)$/.test(el.tagName)) return 'frame';
      if (el.tagName.indexOf('-') >= 0 && !el.shadowRoot) return 'blocked';
      var input = el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && /^(text|search|url|email|tel|)$/.test((el.getAttribute('type') || '').toLowerCase()));
      if (!input && !el.isContentEditable && !/^(BODY|HTML)$/.test(el.tagName)) return 'blocked';
      return (input || el.isContentEditable) && !el.readOnly && !el.disabled ? 'editor' : 'none';
    }
    """

    static let remember = """
    \(helpers)
    var el = snippetElement(), status = snippetStatus(el);
    window.__broadwaySnippetOrigin = null;
    if (status !== 'editor') return status;
    var mark = { el: el };
    if (el.isContentEditable) {
      var selection = getSelection();
      if (!selection || !selection.rangeCount || !el.contains(selection.anchorNode) || !el.contains(selection.focusNode)) return 'blocked';
      mark.range = selection.getRangeAt(0).cloneRange();
    } else {
      mark.start = el.selectionStart || 0;
      mark.end = el.selectionEnd || 0;
    }
    window.__broadwaySnippetOrigin = mark;
    return status;
    """

    static let capture = """
    \(helpers)
    var el = snippetElement(), status = snippetStatus(el);
    window.__broadwaySnippet = null;
    if (status !== 'editor') return status;
    var origin = window.__broadwaySnippetOrigin;
    var mark = { el: el, token: token };
    if (origin && origin.el === el) {
      if (origin.range) mark.range = origin.range.cloneRange();
      else { mark.start = origin.start; mark.end = origin.end; }
    } else if (el.isContentEditable) {
      var selection = getSelection();
      if (!selection || !selection.rangeCount || !el.contains(selection.anchorNode) || !el.contains(selection.focusNode)) return 'blocked';
      mark.range = selection.getRangeAt(0).cloneRange();
    } else {
      mark.start = el.selectionStart || 0;
      mark.end = el.selectionEnd || 0;
    }
    window.__broadwaySnippet = mark;
    return status;
    """

    static let validate = """
    \(helpers)
    var el = snippetElement(), status = snippetStatus(el);
    if (status !== 'editor') return status;
    var mark = window.__broadwaySnippet;
    return mark && mark.token === token && mark.el === el && el.isConnected ? 'editor' : 'blocked';
    """

    static let insert = """
    \(helpers)
    var mark = window.__broadwaySnippet, el = snippetElement();
    if (!mark || mark.token !== token || mark.el !== el || !el.isConnected || snippetStatus(el) !== 'editor') return false;
    el.focus();
    if (mark.range) {
      var selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(mark.range);
    } else if (typeof el.selectionStart === 'number') {
      el.setSelectionRange(mark.start, mark.end);
    }
    var from = !el.isContentEditable && typeof el.selectionStart === 'number' ? el.selectionStart : 0;
    var inserted = document.execCommand('insertText', false, text);
    window.__broadwaySnippet = null;
    if (inserted && tail) {
      if (!el.isContentEditable && typeof el.selectionEnd === 'number') {
        var stored = el.value.substring(from, el.selectionEnd);
        var shapes = [tail, tail.replace(/\\r\\n/g, '\\n'), tail.replace(/[\\r\\n]/g, ''), tail.replace(/\\r\\n|\\r|\\n/g, ' ')];
        var left = shapes.filter(function (shape) { return stored.slice(stored.length - shape.length) === shape; })[0] || tail;
        var at = Math.max(from, el.selectionEnd - left.length);
        el.setSelectionRange(at, at);
      } else {
        var moved = getSelection();
        var steps = typeof Intl !== 'undefined' && Intl.Segmenter ? Array.from(new Intl.Segmenter().segment(tail)).length : Array.from(tail).length;
        for (var step = 0; step < steps; step++) moved.modify('move', 'backward', 'character');
      }
    }
    return inserted;
    """
}

@MainActor
final class SnippetField {
    struct Target {
        var tab: Tab.ID?
        var url: URL?
        var web: WKWebView?
        var frame: WKFrameInfo?
        var token: String
        var editor: Bool
    }

    var request = UUID()
    var selectionRequest = UUID()
    var selectionFailed = false
    var target: Target?
    var waiting = false
    var submitWhenReady = false
    var submission = (aside: false, front: false)
    var queued: Snippet?
    var checked: String?

    func reset() {
        request = UUID()
        target = nil
        waiting = false
        submitWhenReady = false
        queued = nil
        checked = nil
    }
}

extension Browser {
    func rememberSnippetSelection(_ done: @escaping () -> Void) {
        guard !SnippetStore.shared.snippets.isEmpty, let tab = active, tab.page == nil, tab.built != nil else { done(); return }
        let request = UUID()
        snippetField.selectionRequest = request
        snippetField.selectionFailed = false
        var finished = false
        let finish: (Bool) -> Void = { [weak self] success in
            guard !finished else { return }
            finished = true
            if self?.snippetField.selectionRequest == request { self?.snippetField.selectionFailed = !success }
            done()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { finish(false) }
        Task {
            var status = await PageSelection.run(tab, SnippetPage.remember) as? String
            if status == "frame" {
                if let frame = tab.snippetFrame { status = await PageSelection.run(tab, SnippetPage.remember, in: frame) as? String }
                else { status = nil }
            }
            finish(status != nil)
        }
    }

    func addSnippetRows() {
        let snippets = SnippetStore.shared.matches(typed)
        guard !snippets.isEmpty, siteChip == nil, fieldPlace == nil, !summoning else { return }
        snippetField.waiting = true
        let request = snippetField.request
        let text = typed
        let tab = active
        let web = tab?.built
        let url = tab?.shownURL
        let token = UUID().uuidString
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak tab] in
            guard let self, snippetField.request == request, snippetField.waiting else { return }
            let submit = snippetField.submitWhenReady
            let submission = snippetField.submission
            if !submit {
                snippetField.waiting = false
                snippetField.checked = "expired"
                return
            }
            snippetField.reset()
            snippetField.checked = "expired"
            guard submit, typed == text, active?.id == tab?.id, tab?.built === web, tab?.shownURL == url,
                  fieldShowing, siteChip == nil, !summoning, picked == nil else { return }
            self.submit(aside: submission.aside, front: submission.front)
        }
        Task { [weak self, weak tab] in
            var frame: WKFrameInfo?
            var status = "none"
            if let tab, web != nil, tab.page == nil {
                status = await PageSelection.run(tab, SnippetPage.capture, ["token": token]) as? String ?? "blocked"
                if status == "frame" {
                    frame = tab.snippetFrame
                    if let frame {
                        status = await PageSelection.run(tab, SnippetPage.capture, ["token": token], in: frame) as? String ?? "blocked"
                    } else { status = "blocked" }
                }
            }
            guard let self, snippetField.request == request else { return }
            snippetField.waiting = false
            snippetField.checked = status
            guard typed == text,
                  active?.id == tab?.id, tab?.built === web, tab?.shownURL == url,
                  fieldShowing, siteChip == nil, fieldPlace == nil, !summoning
            else { snippetField.submitWhenReady = false; return }
            if status == "editor", snippetField.selectionFailed { status = "blocked" }
            guard status == "none" || status == "editor" else {
                if snippetField.submitWhenReady { announce("Snippets aren't available in this field") }
                snippetField.submitWhenReady = false
                return
            }
            guard picked == nil else { snippetField.submitWhenReady = false; return }
            snippetField.target = .init(tab: tab?.id, url: url, web: web, frame: frame, token: token, editor: status == "editor")
            for index in offers.indices { offers[index].leads = false }
            let rows = snippets.enumerated().map { index, snippet in
                var row = Suggestion(key: snippet.title, title: ";" + snippet.keyword, url: FieldAction.nowhere, kind: .snippet(snippet))
                row.leads = index == 0
                return row
            }
            if let pointed, pointed >= 0 { self.pointed = pointed + rows.count }
            offers.insert(contentsOf: rows, at: 0)
            ending = nil
            if snippetField.submitWhenReady {
                snippetField.submitWhenReady = false
                useSnippet(snippets[0])
            }
        }
    }

    func addSnippetPlaceRows() {
        offers = SnippetStore.shared.listed(matching: typed).map { snippet in
            Suggestion(key: snippet.title, title: ";" + snippet.keyword, url: FieldAction.nowhere, kind: .snippet(snippet))
        }
        picked = offers.isEmpty ? nil : 0
        guard !offers.isEmpty else { return }
        snippetField.waiting = true
        let request = snippetField.request
        let text = typed
        let tab = active
        let web = tab?.built
        let url = tab?.shownURL
        let token = UUID().uuidString
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, snippetField.request == request, snippetField.waiting else { return }
            snippetField.waiting = false
            snippetField.checked = "expired"
            guard snippetField.submitWhenReady else { return }
            snippetField.reset()
            snippetField.checked = "expired"
            announce("That snippet didn't go in", kind: .error)
        }
        Task { [weak self, weak tab] in
            var frame: WKFrameInfo?
            var status = "none"
            if let tab, web != nil, tab.page == nil {
                status = await PageSelection.run(tab, SnippetPage.capture, ["token": token]) as? String ?? "blocked"
                if status == "frame" {
                    frame = tab.snippetFrame
                    if let frame {
                        status = await PageSelection.run(tab, SnippetPage.capture, ["token": token], in: frame) as? String ?? "blocked"
                    } else { status = "blocked" }
                }
            }
            guard let self, snippetField.request == request else { return }
            snippetField.waiting = false
            snippetField.checked = status
            let queued = snippetField.queued
            snippetField.queued = nil
            guard typed == text, active?.id == tab?.id, tab?.built === web, tab?.shownURL == url,
                  fieldShowing, fieldPlace == .snippets
            else { snippetField.submitWhenReady = false; return }
            if status == "editor", snippetField.selectionFailed { status = "blocked" }
            guard status == "none" || status == "editor" else {
                if snippetField.submitWhenReady { announce("Snippets aren't available in this field") }
                snippetField.submitWhenReady = false
                return
            }
            snippetField.target = .init(tab: tab?.id, url: url, web: web, frame: frame, token: token, editor: status == "editor")
            if snippetField.submitWhenReady, let queued {
                snippetField.submitWhenReady = false
                useSnippet(queued)
            }
        }
    }

    func chooseSnippet(_ snippet: Snippet) {
        guard fieldPlace == .snippets else { useSnippet(snippet); return }
        if snippetField.waiting {
            snippetField.queued = snippet
            snippetField.submitWhenReady = true
            return
        }
        guard snippetField.target != nil else {
            announce("Snippets aren't available in this field")
            return
        }
        useSnippet(snippet)
    }

    func submitSnippetPlace() {
        guard !SnippetStore.shared.snippets.isEmpty else {
            quitField()
            show(FieldPlace.snippets.page)
            return
        }
        guard case .snippet(let snippet) = pickedOffer?.kind else { return }
        chooseSnippet(snippet)
    }

    func waitForSnippet(aside: Bool, front: Bool) -> Bool {
        guard snippetField.waiting, picked == nil else { return false }
        snippetField.submitWhenReady = true
        snippetField.submission = (aside, front)
        return true
    }

    var leadingSnippet: Snippet? {
        let row = fieldRow.flatMap { offers.indices.contains($0) ? offers[$0] : nil } ?? offers.first
        if case .snippet(let snippet) = row?.kind, fieldRow != nil || row?.leads == true { return snippet }
        return nil
    }

    func useSnippet(_ snippet: Snippet) {
        guard let target = snippetField.target,
              let current = SnippetStore.shared.snippets.first(where: { $0.id == snippet.id }), current == snippet
        else { retype(); return }
        let tab = active
        Task { [weak self, weak tab] in
            guard let self, active?.id == target.tab, tab?.shownURL == target.url, tab?.built === target.web else { return }
            if let tab, target.web != nil, tab.page == nil {
                let root = await PageSelection.run(tab, SnippetPage.validate, ["token": target.token]) as? String ?? "blocked"
                var status = root
                if root == "frame", let frame = target.frame {
                    status = await PageSelection.run(tab, SnippetPage.validate, ["token": target.token], in: frame) as? String ?? "blocked"
                }
                guard active?.id == target.tab, tab.shownURL == target.url, tab.built === target.web,
                      snippetField.target?.token == target.token,
                      status == (target.editor ? "editor" : "none")
                else { retype(); announce("The field changed, so the snippet didn't go in", kind: .error); return }
                if target.editor {
                    let filled = Snippet.fill(snippet.text, clipboard: AnswerBoard.board.string(forType: .string))
                    quitField()
                    let inserted = await PageSelection.run(tab, SnippetPage.insert, ["token": target.token, "text": filled.text, "tail": filled.tail], in: target.frame) as? Bool ?? false
                    if inserted {
                        SnippetStore.shared.used(snippet.id)
                        if active?.id == tab.id { tab.built?.window?.makeFirstResponder(tab.built) }
                        announce("Inserted snippet")
                    } else { announce("That snippet didn't go in", kind: .error) }
                    return
                }
            }
            let filled = Snippet.fill(snippet.text, clipboard: AnswerBoard.board.string(forType: .string))
            quitField()
            AnswerBoard.write(filled.text)
            SnippetStore.shared.used(snippet.id)
            announce("Copied snippet")
        }
    }
}
