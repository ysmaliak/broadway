import AppKit
import WebKit

enum PageMarkdown {
    struct Read: Equatable {
        let markdown: String
        let selected: Bool
    }

    @MainActor static var copied: String?

    @MainActor static func keep(_ text: String) {
        copied = text
        guard !Store.testing else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor static func read(_ web: WKWebView) async -> Read? {
        let value: Any? = await withCheckedContinuation { done in
            web.evaluateJavaScript(script, in: nil, in: Web.world) { result in done.resume(returning: try? result.get()) }
        }
        guard let found = value as? [String: Any], let markdown = found["markdown"] as? String else { return nil }
        return Read(markdown: markdown, selected: found["selected"] as? Bool ?? false)
    }

    static func text(title: String, url: URL?, read: Read) -> String? {
        let body = read.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        if read.selected { return body }
        var heading = title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        var rest = body
        if let first = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first, first.hasPrefix("# ") {
            let named = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !named.isEmpty, heading.isEmpty || heading == named || heading.contains(named) {
                heading = named
                rest = String(body.dropFirst(first.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        var parts: [String] = []
        if !heading.isEmpty { parts.append("# " + heading) }
        if let url, url.scheme == "http" || url.scheme == "https" || url.scheme == "file" {
            parts.append("Source: " + LinkCopy.markdownAddress(CleanLink.clean(url)))
        }
        if !rest.isEmpty { parts.append(rest) }
        return parts.joined(separator: "\n\n")
    }

    static let script = #"""
    (function () {
      var page = location.href.split('#')[0];
      var parts = [];
      function hold(text, list) { parts.push(text); return '\n\n' + (list ? '\u0002' : '\u0001') + (parts.length - 1) + '\u0001\n\n'; }
      function expand(text) {
        return text.replace(/[\u0001\u0002](\d+)\u0001/g, function (_, n) { return parts[+n]; });
      }
      function tidy(text) {
        return text.replace(/[ \t]*\n[ \t]*/g, '\n').replace(/\n{3,}/g, '\n\n').replace(/^\s+|\s+$/g, '');
      }
      function finish(text) { return expand(tidy(text)); }
      function escape(text) { return text.replace(/([\\`*_\[\]])/g, '\\$1'); }
      function address(url) {
        return url.replace(/ /g, '%20').replace(/\(/g, '%28').replace(/\)/g, '%29').replace(/</g, '%3C').replace(/>/g, '%3E');
      }
      function fence(text, language) {
        var longest = 2, runs = text.match(/`+/g) || [];
        for (var i = 0; i < runs.length; i++) longest = Math.max(longest, runs[i].length);
        var mark = new Array(longest + 2).join('`');
        return mark + (language || '') + '\n' + text.replace(/\n+$/, '') + '\n' + mark;
      }
      function wrap(text, mark) {
        var m = /^(\s*)([\s\S]*?)(\s*)$/.exec(text);
        if (!m[2] || /[\n\u0001\u0002]/.test(m[2])) return text;
        return m[1] + mark + m[2] + mark + m[3];
      }

      var json = document.documentElement.hasAttribute('data-broadway-json') && document.querySelector('body > pre');
      if (json) return { title: document.title || '', markdown: fence(json.textContent, 'json'), selected: false };

      var seen = 0, limit = 200000, picking = false;
    \#(AIPage.common)
      var noise = clutter + ', [role="dialog"], [aria-modal="true"], #onetrust-consent-sdk, #CybotCookiebotDialog, .cc-window, ' +
        '[id*="cookie-banner" i], [class*="cookie-banner" i], [id*="cookie-notice" i], [class*="cookie-notice" i], ' +
        '[id*="cookie-consent" i], [class*="cookie-consent" i], [aria-label*="cookie" i], ' +
        '.ad, .ads, .advert, .advertisement, .adsbygoogle, [id^="google_ads"], [aria-label="advertisement" i], [data-ad-slot]';
      var blocks = { ADDRESS: 1, ARTICLE: 1, ASIDE: 1, BLOCKQUOTE: 1, DD: 1, DETAILS: 1, DIV: 1, DL: 1, DT: 1, FIELDSET: 1,
                     FIGCAPTION: 1, FIGURE: 1, FOOTER: 1, FORM: 1, H1: 1, H2: 1, H3: 1, H4: 1, H5: 1, H6: 1, HEADER: 1,
                     HR: 1, LI: 1, MAIN: 1, NAV: 1, OL: 1, P: 1, PRE: 1, SECTION: 1, SUMMARY: 1, TABLE: 1, UL: 1, TR: 1 };

      function language(el) {
        var code = el.querySelector && el.querySelector('code');
        var names = [el.className, code && code.className, el.getAttribute('data-lang'), el.getAttribute('data-language')].join(' ');
        var m = /(?:^|\s)(?:language|lang)-([\w+#.-]+)/.exec(names);
        if (m) return m[1];
        return el.getAttribute('data-lang') || el.getAttribute('data-language') || '';
      }
      function source(img) {
        var picked = img.currentSrc || img.src || '';
        if (!picked || /^data:/.test(picked)) picked = img.getAttribute('data-src') || img.getAttribute('data-lazy-src') || '';
        if (!picked || /^(data|blob):/.test(picked)) return '';
        try { return new URL(picked, document.baseURI).href; } catch (e) { return ''; }
      }
      function plain(table) {
        var rows = table.rows, count = -1;
        if (!rows || !rows.length) return false;
        if (table.querySelector('table, ul, ol, pre, blockquote, h1, h2, h3, h4, h5, h6')) return false;
        for (var i = 0; i < rows.length; i++) {
          var cells = rows[i].cells;
          if (count === -1) count = cells.length; else if (cells.length !== count) return false;
          for (var j = 0; j < cells.length; j++) if (cells[j].colSpan > 1 || cells[j].rowSpan > 1) return false;
        }
        return count > 0;
      }
      function grid(table) {
        var lines = [];
        for (var i = 0; i < table.rows.length; i++) {
          var cells = [];
          for (var j = 0; j < table.rows[i].cells.length; j++) {
            cells.push(finish(children(table.rows[i].cells[j])).replace(/\n+/g, ' ').replace(/\|/g, '\\|'));
          }
          lines.push('| ' + cells.join(' | ') + ' |');
          if (i === 0) lines.push('|' + cells.map(function () { return ' --- '; }).join('|') + '|');
        }
        return lines.join('\n');
      }
      function list(el) {
        var ordered = el.tagName === 'OL', n = ordered ? (parseInt(el.getAttribute('start'), 10) || 1) : 1, items = [];
        for (var c = el.firstChild; c; c = c.nextSibling) {
          var inner;
          if (c.nodeType === 1 && c.tagName === 'LI') {
            if (!visible(c)) continue;
            inner = finish(children(c).replace(/\n\n(?=\u0002)/g, '\n'));
          } else {
            inner = finish(convert(c));
            if (!inner) continue;
          }
          var marker = ordered ? (n++) + '. ' : '- ', pad = new Array(marker.length + 1).join(' ');
          items.push(marker + inner.split('\n').map(function (line, i) { return i && line ? pad + line : line; }).join('\n'));
        }
        return items.length ? hold(items.join('\n'), true) : '';
      }
      function visible(el) {
        if (picking) return true;
        if (el !== root && el.matches && el.matches(noise)) return false;
        if (!shown(el)) return false;
        return getComputedStyle(el).position !== 'fixed' || el === root;
      }
      function block(el) {
        if (picking) return !!blocks[el.tagName];
        var display = getComputedStyle(el).display;
        return display !== 'contents' && !/^inline/.test(display);
      }
      function children(el) {
        var out = '';
        for (var c = el.firstChild; c; c = c.nextSibling) out += convert(c);
        return out;
      }
      function convert(node) {
        if (seen++ > limit) return '';
        if (node.nodeType === 3) return escape(node.nodeValue.replace(/\s+/g, ' '));
        if (node.nodeType !== 1) return '';
        var tag = node.tagName.toUpperCase();
        if (tag === 'INPUT' && node.type === 'checkbox') return node.checked ? '[x] ' : '[ ] ';
        if (skip[tag] || tag === 'BUTTON') return '';
        if (tag === 'BR') return '\n';
        if (!visible(node)) return '';
        var inner;
        switch (tag) {
        case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6':
          inner = finish(children(node)).replace(/\s*\n+\s*/g, ' ');
          return inner ? hold(new Array(+tag[1] + 1).join('#') + ' ' + inner) : '';
        case 'PRE':
          return hold(fence(node.textContent, language(node)));
        case 'CODE': case 'KBD': case 'SAMP':
          inner = node.textContent.replace(/\s+/g, ' ');
          if (!inner.trim()) return '';
          var ticks = inner.indexOf('`') >= 0 ? '``' : '`';
          return ticks + (ticks.length > 1 ? ' ' + inner + ' ' : inner) + ticks;
        case 'STRONG': case 'B':
          return wrap(children(node), '**');
        case 'EM': case 'I': case 'CITE':
          return wrap(children(node), '*');
        case 'DEL': case 'S': case 'STRIKE':
          return wrap(children(node), '~~');
        case 'A':
          inner = children(node);
          var href = node.href || '';
          if (!href || /^(javascript|data):/i.test(href)) return inner;
          if (href.split('#')[0] === page && href.indexOf('#') >= 0) {
            return /^\s*(#|¶|§|🔗)?\s*$/.test(inner) ? '' : inner;
          }
          if (!inner.trim() || /[\n\u0001\u0002]/.test(inner.trim())) return inner;
          var m = /^(\s*)([\s\S]*?)(\s*)$/.exec(inner);
          return m[1] + '[' + m[2] + '](' + address(href) + ')' + m[3];
        case 'IMG':
          var src = source(node);
          if (!src) return '';
          return '![' + escape((node.alt || '').replace(/\s+/g, ' ').trim()) + '](' + address(src) + ')';
        case 'UL': case 'OL':
          return list(node);
        case 'BLOCKQUOTE':
          inner = finish(children(node));
          return inner ? hold(inner.split('\n').map(function (line) { return line ? '> ' + line : '>'; }).join('\n')) : '';
        case 'TABLE':
          if (plain(node)) return hold(grid(node));
          break;
        case 'HR':
          return hold('---');
        case 'DT':
          inner = finish(children(node));
          return inner ? hold('**' + inner + '**') : '';
        }
        inner = children(node);
        return block(node) ? '\n\n' + inner + '\n\n' : inner;
      }

      var field = document.activeElement;
      if (field && (field.tagName === 'TEXTAREA' || (field.tagName === 'INPUT' && field.type !== 'password'))) {
        try {
          var from = field.selectionStart, to = field.selectionEnd;
          if (typeof from === 'number' && to > from) return { title: document.title || '', markdown: field.value.slice(from, to), selected: true };
        } catch (e) {}
      }
      var root = null;
      var selection = window.getSelection();
      if (selection && selection.rangeCount && !selection.isCollapsed && String(selection).trim()) {
        var range = selection.getRangeAt(0), at = range.commonAncestorContainer;
        if (at.nodeType !== 1) at = at.parentElement;
        var holder = at && (at.closest('pre') || at.closest('code'));
        if (!holder && at && /^(UL|OL|BLOCKQUOTE|TABLE)$/.test(at.tagName)) holder = at;
        if (!holder && at && /^(TBODY|THEAD|TFOOT)$/.test(at.tagName)) holder = at.closest('table');
        root = holder ? holder.cloneNode(false) : document.createElement('div');
        root.appendChild(range.cloneContents());
        picking = true;
        var picked = finish(convert(root));
        return { title: document.title || '', markdown: picked || String(selection), selected: true };
      }
      root = article() || document.body;
      if (!root) return null;
      return { title: document.title || '', markdown: finish(convert(root)), selected: false };
    })();
    """#
}

extension Browser {
    func copyPageAsMarkdown(_ asked: Tab? = nil) {
        guard let tab = asked ?? active, tab.isWeb, let web = tab.built else { return }
        Task { @MainActor [weak self, weak tab] in
            let read = await PageMarkdown.read(web)
            guard let self, let tab else { return }
            guard let read, let text = PageMarkdown.text(title: tab.title, url: tab.pageAddress, read: read) else {
                self.announce("Nothing to copy here")
                return
            }
            PageMarkdown.keep(text)
            self.announce("Copied as Markdown")
        }
    }
}
