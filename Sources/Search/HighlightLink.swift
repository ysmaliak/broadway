import AppKit
import WebKit

enum HighlightLink {
    static let whole = 300
    static let ends = 5
    static let lead = 3

    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~")

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    static func base(_ url: URL) -> String {
        var text = url.absoluteString
        if let hash = text.firstIndex(of: "#"), let directive = text.range(of: ":~:", range: hash..<text.endIndex) {
            text = String(text[..<directive.lowerBound])
        }
        if text.hasSuffix("#") { text.removeLast() }
        return text
    }

    static func term(selection: String, before: String) -> String? {
        let lines = selection.components(separatedBy: .newlines).map(words).filter { !$0.isEmpty }
        guard let opening = lines.first, let closing = lines.last else { return nil }
        let picked = lines.flatMap { $0 }
        let flat = picked.joined(separator: " ")
        let first: String
        var term: String
        if lines.count == 1, flat.count <= whole {
            first = flat
            term = encode(flat)
        } else {
            first = opening.prefix(ends).joined(separator: " ")
            term = encode(first) + "," + encode(closing.suffix(ends).joined(separator: " "))
        }
        let earlier = words(before)
        let near = words(before.components(separatedBy: .newlines).last ?? "")
        if !near.isEmpty, earlier.joined(separator: " ").range(of: first, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            term = encode(near.suffix(lead).joined(separator: " ")) + "-," + term
        }
        return term
    }

    static func address(_ url: URL, selection: String, before: String) -> URL? {
        guard ["http", "https", "file"].contains(url.scheme?.lowercased() ?? ""),
              let term = term(selection: selection, before: before) else { return nil }
        let base = base(url)
        let joint = base.contains("#") ? ":~:text=" : "#:~:text="
        return URL(string: base + joint + term)
    }

    static let read = """
    (function () {
      var el = document.activeElement;
      if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) return null;
      var picked = getSelection();
      if (!picked || picked.isCollapsed || !picked.rangeCount) return null;
      if (!picked.toString().trim()) return null;
      var range = picked.getRangeAt(0).cloneRange();
      var letter = /[\\p{L}\\p{N}]/u;
      var lead = '', tail = '';
      var from = range.startContainer, at = range.startOffset;
      if (from.nodeType === 3 && at > 0 && at < from.data.length && letter.test(from.data[at - 1]) && letter.test(from.data[at])) {
        var began = at;
        while (at > 0 && letter.test(from.data[at - 1])) at--;
        lead = from.data.slice(at, began);
        range.setStart(from, at);
      }
      var to = range.endContainer, end = range.endOffset;
      if (to.nodeType === 3 && end > 0 && end < to.data.length && letter.test(to.data[end - 1]) && letter.test(to.data[end])) {
        var ended = end;
        while (end < to.data.length && letter.test(to.data[end])) end++;
        tail = to.data.slice(ended, end);
        range.setEnd(to, end);
      }
      var text = lead + picked.toString() + tail;
      var root = document.body || document.documentElement;
      var skip = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1 };
      function block(node) {
        for (var at = node.parentElement; at && at !== root; at = at.parentElement) {
          var shown = getComputedStyle(at).display || '';
          if (shown.indexOf('inline') !== 0) return at;
        }
        return root;
      }
      var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
        acceptNode: function (node) { return node.parentElement && skip[node.parentElement.tagName] ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT; }
      });
      var parts = [], last = null;
      for (var node = walker.nextNode(); node; node = walker.nextNode()) {
        var stop = node === range.startContainer;
        if (!stop && !(range.comparePoint(node, 0) < 0)) break;
        var piece = stop ? node.data.slice(0, range.startOffset) : node.data;
        var here = block(node);
        if (last && here !== last) parts.push('\\n');
        parts.push(piece);
        last = here;
        if (stop) break;
      }
      var before = parts.join('');
      return { text: text, before: before.length > 200000 ? before.slice(-200000) : before };
    })()
    """
}

extension Browser {
    var canCopyLinkToHighlight: Bool {
        guard let tab = active, let url = tab.address, tab.page == nil else { return false }
        return ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "")
    }

    func copyLinkToHighlight(_ asked: Tab? = nil) {
        guard let tab = asked ?? active, let url = tab.address, tab.page == nil, let web = tab.built else { return }
        web.evaluateJavaScript(HighlightLink.read, in: nil, in: Web.world) { [weak self, weak tab] result in
            guard let self, let tab, let found = (try? result.get()) as? [String: Any],
                  let text = found["text"] as? String,
                  let link = HighlightLink.address(url, selection: text, before: found["before"] as? String ?? "")
            else { return }
            guard LinkCopy.copy([LinkCopy.Link(tab.title, link)], as: .address, to: LinkCopy.board) else { return }
            self.announce("Link to highlight copied")
        }
    }
}
