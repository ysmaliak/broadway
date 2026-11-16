import AppKit
import WebKit

enum JSONMode: String, CaseIterable {
    case tree, pretty, raw
}

@MainActor
enum JSONView {
    static let key = "pages.json"
    nonisolated static let modeToken = "__BROADWAY_JSON_MODE__"

    static var mode: JSONMode {
        get { Store.settings.string(forKey: key).flatMap(JSONMode.init(rawValue:)) ?? .tree }
        set { Store.settings.set(newValue.rawValue, forKey: key) }
    }

    static var copied: String?

    static func keep(_ text: String) {
        copied = text
        guard !Store.testing else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static var script: WKUserScript {
        WKUserScript(source: source(for: mode), injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)
    }

    nonisolated static func source(for mode: JSONMode) -> String {
        core + page.replacingOccurrences(of: modeToken, with: mode.rawValue)
    }

    struct Row {
        let id: Int
        let path: String
        let at: Date
    }

    private static var rows: [ObjectIdentifier: Row] = [:]

    static func pointed(_ row: Row?, in web: WKWebView) {
        rows[ObjectIdentifier(web)] = row
    }

    static func addItems(to menu: NSMenu, in web: WKWebView) {
        guard let row = rows.removeValue(forKey: ObjectIdentifier(web)), Date().timeIntervalSince(row.at) < 2 else { return }
        let value = NSMenuItem(title: "Copy Value", action: #selector(JSONMenuTarget.copyValue(_:)), keyEquivalent: "")
        value.identifier = NSUserInterfaceItemIdentifier("BroadwayJSONCopyValue")
        let path = NSMenuItem(title: "Copy Path", action: #selector(JSONMenuTarget.copyPath(_:)), keyEquivalent: "")
        path.identifier = NSUserInterfaceItemIdentifier("BroadwayJSONCopyPath")
        for item in [value, path] {
            item.target = JSONMenuTarget.shared
            item.representedObject = JSONMenuTarget.Pick(web: web, row: row)
        }
        menu.insertItem(value, at: 0)
        menu.insertItem(path, at: 1)
        if menu.items.count > 2 { menu.insertItem(.separator(), at: 2) }
    }

    static func copyValue(of row: Int, in web: WKWebView) {
        web.evaluateJavaScript("window.__broadwayJSON ? window.__broadwayJSON.value(\(row)) : null", in: nil, in: Web.world) { result in
            guard case .success(let value) = result, let text = value as? String else { return }
            keep(text)
        }
    }
}

@MainActor
final class JSONMenuTarget: NSObject {
    static let shared = JSONMenuTarget()

    final class Pick: NSObject {
        weak var web: WKWebView?
        let row: JSONView.Row
        init(web: WKWebView, row: JSONView.Row) {
            self.web = web
            self.row = row
        }
    }

    @objc func copyValue(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick, let web = pick.web else { return }
        JSONView.copyValue(of: pick.row.id, in: web)
    }

    @objc func copyPath(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick else { return }
        JSONView.keep(pick.row.path)
    }
}

final class JSONRelay: NSObject, WKScriptMessageHandler {
    static let name = "broadwayJSON"

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
            if let raw = body["mode"] as? String, let mode = JSONMode(rawValue: raw) {
                JSONView.mode = mode
            }
            if body.keys.contains("menu"), let web = message.webView {
                let menu = body["menu"] as? [String: Any]
                let row = (menu?["id"] as? NSNumber).flatMap { id in
                    (menu?["path"] as? String).map { JSONView.Row(id: id.intValue, path: $0, at: Date()) }
                }
                JSONView.pointed(row, in: web)
            }
        }
    }
}

extension JSONView {
    nonisolated static let core = #"""
    var __broadwayJSONCore = (function () {
      function classify(type, path) {
        type = String(type || '').toLowerCase().split(';')[0].trim();
        if (type === 'application/json' || type === 'text/json' || /^application\/[a-z0-9.!#$&^_-]+\+json$/.test(type)) return 'declared';
        if (type === 'text/plain' && /\.json$/i.test(String(path || ''))) return 'named';
        return null;
      }
      function parse(t) {
        var i = 0, n = t.length;
        if (t.charCodeAt(0) === 0xFEFF) i = 1;
        var number = /-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/y;
        function fail(msg) { throw { at: i, msg: msg }; }
        function end() { return i >= n; }
        function ws() {
          for (; i < n; i++) {
            var c = t.charCodeAt(i);
            if (c !== 32 && c !== 10 && c !== 13 && c !== 9) break;
          }
        }
        function str() {
          var s = ++i, esc = false;
          for (;;) {
            if (i >= n) { i = s - 1; fail('Unterminated string'); }
            var c = t.charCodeAt(i);
            if (c === 34) break;
            if (c === 92) { esc = true; i += 2; continue; }
            if (c < 32) fail('Control character in a string');
            i++;
          }
          i++;
          if (!esc) return t.slice(s, i - 1);
          try { return JSON.parse(t.slice(s - 1, i)); } catch (e) { i = s - 1; fail('Bad escape in a string'); }
        }
        function value(depth) {
          if (depth > 4000) fail('Nested too deeply');
          ws();
          if (end()) fail('Unexpected end of data');
          var c = t.charCodeAt(i);
          if (c === 123) {
            i++;
            var keys = [], vals = [];
            ws();
            if (t.charCodeAt(i) === 125) { i++; return { k: 'o', keys: keys, vals: vals }; }
            for (;;) {
              ws();
              if (t.charCodeAt(i) !== 34) fail(end() ? 'Unexpected end of data' : 'Expected a key in double quotes');
              keys.push(str());
              ws();
              if (t.charCodeAt(i) !== 58) fail(end() ? 'Unexpected end of data' : 'Expected “:” after a key');
              i++;
              vals.push(value(depth + 1));
              ws();
              c = t.charCodeAt(i);
              if (c === 44) { i++; continue; }
              if (c === 125) { i++; return { k: 'o', keys: keys, vals: vals }; }
              fail(end() ? 'Unexpected end of data' : 'Expected “,” or “}”');
            }
          }
          if (c === 91) {
            i++;
            var items = [];
            ws();
            if (t.charCodeAt(i) === 93) { i++; return { k: 'a', vals: items }; }
            for (;;) {
              items.push(value(depth + 1));
              ws();
              c = t.charCodeAt(i);
              if (c === 44) { i++; continue; }
              if (c === 93) { i++; return { k: 'a', vals: items }; }
              fail(end() ? 'Unexpected end of data' : 'Expected “,” or “]”');
            }
          }
          if (c === 34) return { k: 's', v: str() };
          if (c === 45 || (c >= 48 && c <= 57)) {
            number.lastIndex = i;
            var m = number.exec(t);
            if (!m) fail('Bad number');
            i += m[0].length;
            return { k: 'n', v: m[0] };
          }
          if (t.startsWith('true', i)) { i += 4; return { k: 'b', v: 'true' }; }
          if (t.startsWith('false', i)) { i += 5; return { k: 'b', v: 'false' }; }
          if (t.startsWith('null', i)) { i += 4; return { k: 'z', v: 'null' }; }
          fail('Unexpected character “' + t.charAt(i) + '”');
        }
        var root;
        try {
          root = value(0);
        } catch (e) {
          if (e instanceof RangeError) throw { at: i, msg: 'Nested too deeply' };
          throw e;
        }
        ws();
        if (i < n) fail('Unexpected text after the JSON');
        return root;
      }
      function where(t, at) {
        var line = 1, col = 1;
        for (var j = 0; j < at && j < t.length; j++) {
          if (t.charCodeAt(j) === 10) { line++; col = 1; } else col++;
        }
        return { line: line, column: col };
      }
      function boxed(node) { return node.k === 'o' || node.k === 'a'; }
      function size(node) { return boxed(node) ? node.vals.length : 0; }
      function step(key) {
        if (typeof key === 'number') return '[' + key + ']';
        return /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(key) ? '.' + key : '[' + JSON.stringify(key) + ']';
      }
      function path(keys) {
        var out = '$';
        for (var j = 0; j < keys.length; j++) out += step(keys[j]);
        return out;
      }
      function write(node, indent, out, pad) {
        if (node.k === 's') { out.push(JSON.stringify(node.v)); return; }
        if (!boxed(node)) { out.push(node.v); return; }
        var open = node.k === 'o' ? '{' : '[', close = node.k === 'o' ? '}' : ']';
        if (!node.vals.length) { out.push(open + close); return; }
        var inner = pad + indent, br = indent ? '\n' : '';
        out.push(open + br);
        for (var j = 0; j < node.vals.length; j++) {
          out.push(inner);
          if (node.k === 'o') out.push(JSON.stringify(node.keys[j]) + (indent ? ': ' : ':'));
          write(node.vals[j], indent, out, inner);
          if (j < node.vals.length - 1) out.push(',');
          out.push(br);
        }
        out.push(pad + close);
      }
      function text(node, indent) {
        var out = [];
        write(node, indent === undefined ? '  ' : indent, out, '');
        return out.join('');
      }
      function value(node) {
        if (node.k === 's') return node.v;
        if (!boxed(node)) return node.v;
        return text(node, '  ');
      }
      return { classify: classify, parse: parse, where: where, boxed: boxed, size: size, path: path, text: text, value: value };
    })();
    """#

    nonisolated static let page = #"""
    (function () {
      if (window.__broadwayJSON || window.top !== window) return;
      var C = __broadwayJSONCore, doc = document, body = doc.body, html = doc.documentElement;
      var kind = C.classify(doc.contentType, location.pathname);
      if (!kind || !body || body.children.length !== 1 || body.firstElementChild.tagName !== 'PRE') return;
      var pre = body.firstElementChild, raw = pre.textContent;
      var CAP = 8 * 1024 * 1024, CHUNK = 500, BUDGET = 1500, PAINT = 512 * 1024, ALL = 50000;
      var relay = window.webkit && webkit.messageHandlers && webkit.messageHandlers.broadwayJSON;
      var big = raw.length > CAP, tree = null, error = null;
      function load() {
        if (tree || error) return;
        try { tree = C.parse(raw); } catch (e) { error = e && e.at !== undefined ? e : { at: 0, msg: String((e && e.message) || e) }; }
      }
      if (kind === 'named') {
        if (big) return;
        load();
        if (!tree) return;
      }
      var wanted = '__BROADWAY_JSON_MODE__';
      if (wanted !== 'raw' && !big) load();

      function el(tag, cls, text) {
        var e = doc.createElement(tag);
        if (cls) e.className = cls;
        if (text !== undefined) e.textContent = text;
        return e;
      }
      function bytes(n) {
        if (n < 1000) return n + ' bytes';
        if (n < 1000000) return (n / 1000).toFixed(1) + ' KB';
        return (n / 1000000).toFixed(1) + ' MB';
      }

      var style = el('style');
      style.textContent = [
        ':root{color-scheme:light dark;--bg:#fff;--fg:#1d1d1f;--dim:#8a8a8e;--key:#0b4f8a;--str:#c41a16;--num:#1c00cf;--lit:#9b2393;--null:#6e6e73;--hover:rgba(0,0,0,.04);--sel:rgba(0,122,255,.13);--bar:rgba(250,250,250,.95);--rule:rgba(0,0,0,.1);--seg:rgba(0,0,0,.06);--on:#fff;--onfg:#1d1d1f;--shadow:0 0 0 .5px rgba(0,0,0,.12),0 1px 2px rgba(0,0,0,.12);--warn:#b25000}',
        '@media (prefers-color-scheme:dark){:root{--bg:#1e1e1e;--fg:#e6e6e8;--dim:#98989d;--key:#7cc4f8;--str:#fc6a5d;--num:#d9c97c;--lit:#fc5fa3;--null:#a1a1a6;--hover:rgba(255,255,255,.05);--sel:rgba(10,132,255,.3);--bar:rgba(36,36,36,.95);--rule:rgba(255,255,255,.12);--seg:rgba(255,255,255,.08);--on:#5a5a5e;--onfg:#fff;--shadow:0 0 0 .5px rgba(0,0,0,.4),0 1px 2px rgba(0,0,0,.3);--warn:#ffb340}}',
        'html,body{margin:0;background:var(--bg);color:var(--fg)}',
        'body{font:12px/1.5 ui-monospace,"SF Mono",Menlo,monospace}',
        'body>pre{margin:0;padding:10px 16px;font:inherit;white-space:pre-wrap;word-wrap:break-word}',
        '.aj-bar{position:sticky;top:0;z-index:2;display:flex;align-items:center;gap:8px;padding:6px 12px;background:var(--bar);-webkit-backdrop-filter:saturate(1.8) blur(20px);backdrop-filter:saturate(1.8) blur(20px);border-bottom:.5px solid var(--rule);font:12px/1 -apple-system,system-ui,sans-serif;-webkit-user-select:none;user-select:none}',
        '.aj-seg{display:inline-flex;padding:2px;border-radius:7px;background:var(--seg)}',
        '.aj-seg button,.aj-btn{appearance:none;border:0;background:transparent;color:var(--fg);font:inherit;padding:4px 10px;border-radius:5px;cursor:default}',
        '.aj-seg button[aria-pressed=true]{background:var(--on);color:var(--onfg);box-shadow:var(--shadow)}',
        '.aj-seg button:disabled{opacity:.4}',
        '.aj-btn{color:var(--dim)}.aj-btn:hover{color:var(--fg);background:var(--seg)}',
        '[data-label]::before{content:attr(data-label)}',
        '.aj-info{margin-left:auto;color:var(--dim)}',
        '.aj-note{padding:8px 16px;border-bottom:.5px solid var(--rule);font:12px/1.4 -apple-system,system-ui,sans-serif;color:var(--warn)}',
        '.aj-note .aj-btn{margin-left:8px;color:var(--fg);background:var(--seg)}',
        '.aj-tree{padding:6px 0 24px}',
        '.aj-line{display:flex;align-items:baseline;padding:1px 12px 1px calc(var(--d,0) * 16px + 12px);border-radius:0;cursor:default}',
        '.aj-line:hover{background:var(--hover)}',
        '.aj-sel>.aj-line{background:var(--sel)}',
        '.aj-tog{flex:none;width:14px;color:var(--dim);font-size:9px;text-align:center}',
        '.aj-box>.aj-line>.aj-tog::before{content:"\\25B6";display:inline-block;transition:transform .12s ease}',
        '.aj-open>.aj-line>.aj-tog::before{transform:rotate(90deg)}',
        '.aj-k{color:var(--key);white-space:pre}',
        '.aj-i{color:var(--dim)}',
        '.aj-c{color:var(--dim);white-space:pre}',
        '.aj-v{min-width:0;white-space:pre-wrap;word-break:break-word}',
        '.aj-s{color:var(--str)}.aj-s a{color:inherit;text-decoration:underline;text-decoration-color:color-mix(in srgb,currentColor 40%,transparent)}',
        '.aj-n{color:var(--num)}.aj-b{color:var(--lit);font-weight:600}.aj-z{color:var(--null);font-weight:600}',
        '.aj-sum{color:var(--dim)}',
        '.aj-box:not(.aj-open)>.aj-line>.aj-sum::before{content:attr(data-shut)}',
        '.aj-sum::after{content:attr(data-count);opacity:.8}','.aj-box:not(.aj-open)>.aj-line>.aj-sum::after{margin-left:6px}',
        '.aj-more{padding:2px 12px 2px calc(var(--d,0) * 16px + 26px)}',
        '.aj-more .aj-btn{padding:2px 8px;margin-right:6px;color:var(--key);background:var(--seg)}',
        '.aj-pretty{margin:0;padding:10px 16px;font:inherit;white-space:pre-wrap;word-wrap:break-word}',
        '.aj-pretty .aj-k{white-space:pre-wrap}'
      ].join('\n');
      (doc.head || html).appendChild(style);

      var bar = el('div', 'aj-bar');
      var seg = el('div', 'aj-seg');
      seg.setAttribute('role', 'group');
      var buttons = {};
      [['tree', 'Tree'], ['pretty', 'Pretty'], ['raw', 'Raw']].forEach(function (m) {
        var b = el('button');
        b.type = 'button';
        b.setAttribute('data-label', m[1]);
        b.setAttribute('aria-label', m[1]);
        b.addEventListener('click', function () { show(m[0], true); });
        buttons[m[0]] = b;
        seg.appendChild(b);
      });
      bar.appendChild(seg);
      var expand = el('button', 'aj-btn'), collapse = el('button', 'aj-btn');
      expand.setAttribute('data-label', 'Expand All');
      expand.setAttribute('aria-label', 'Expand All');
      collapse.setAttribute('data-label', 'Collapse All');
      collapse.setAttribute('aria-label', 'Collapse All');
      expand.addEventListener('click', function () { if (rootInfo) openAll(rootInfo); });
      collapse.addEventListener('click', function () { if (rootInfo) shutAll(); });
      bar.appendChild(expand);
      bar.appendChild(collapse);
      var infoText = el('span', 'aj-info');
      infoText.setAttribute('data-label', bytes(raw.length) + ' · ' + (doc.contentType || 'text/plain'));
      bar.appendChild(infoText);
      var note = el('div', 'aj-note');
      note.hidden = true;
      var treeBox = el('div', 'aj-tree'), prettyBox = el('div', 'aj-pretty');
      treeBox.hidden = prettyBox.hidden = true;
      treeBox.setAttribute('role', 'tree');
      body.insertBefore(prettyBox, pre);
      body.insertBefore(treeBox, prettyBox);
      body.insertBefore(note, treeBox);
      body.insertBefore(bar, note);

      var infos = [], rootInfo = null, selected = null, plan = null, current = null;

      function child(node, j) { return node.vals[j]; }
      function keyOf(node, j) { return node.k === 'o' ? node.keys[j] : j; }
      function keys(inf) {
        var out = [];
        for (var p = inf; p && p.parent; p = p.parent) out.push(p.key);
        return out.reverse();
      }
      function counted(node) {
        var n = node.vals.length;
        return node.k === 'o' ? n + (n === 1 ? ' key' : ' keys') : n + (n === 1 ? ' item' : ' items');
      }
      function link(v) {
        return v.length < 2048 && /^https?:\/\/[^\s"<>]+$/i.test(v);
      }
      function leaf(node, escaped) {
        var v = el('span', 'aj-v aj-' + node.k);
        if (node.k === 's') {
          var text = escaped ? JSON.stringify(node.v).slice(1, -1) : node.v;
          v.appendChild(doc.createTextNode('"'));
          if (link(node.v)) {
            var a = el('a', null, text);
            a.href = node.v;
            v.appendChild(a);
          } else {
            v.appendChild(doc.createTextNode(text));
          }
          v.appendChild(doc.createTextNode('"'));
        } else {
          v.textContent = node.v;
        }
        return v;
      }
      function row(node, parent, key, depth) {
        var inf = { id: infos.length, node: node, parent: parent, key: key, depth: depth, open: false, kids: null, shown: 0, more: null };
        infos.push(inf);
        var r = el('div', 'aj-row');
        r.setAttribute('role', 'treeitem');
        r.dataset.id = inf.id;
        var line = el('div', 'aj-line');
        line.style.setProperty('--d', depth);
        line.appendChild(el('span', 'aj-tog'));
        if (key !== undefined) {
          line.appendChild(typeof key === 'number' ? el('span', 'aj-k aj-i', String(key)) : el('span', 'aj-k', key));
          line.appendChild(el('span', 'aj-c', ': '));
        }
        if (C.boxed(node)) {
          var sum = el('span', 'aj-v aj-sum');
          var o = node.k === 'o';
          if (node.vals.length) {
            r.classList.add('aj-box');
            sum.setAttribute('data-shut', o ? '{…}' : '[…]');
            sum.setAttribute('data-count', counted(node));
            r.setAttribute('aria-expanded', 'false');
          } else {
            sum.setAttribute('data-label', o ? '{}' : '[]');
          }
          line.appendChild(sum);
        } else {
          line.appendChild(leaf(node));
        }
        r.appendChild(line);
        inf.row = r;
        if (plan && plan.has(node)) open(inf, true);
        return r;
      }
      function open(inf, on, limit) {
        if (!C.boxed(inf.node) || !inf.node.vals.length || inf.open === on) return;
        inf.open = on;
        inf.row.classList.toggle('aj-open', on);
        inf.row.setAttribute('aria-expanded', on ? 'true' : 'false');
        if (on && !inf.kids) {
          inf.kids = el('div', 'aj-kids');
          inf.kids.setAttribute('role', 'group');
          inf.row.appendChild(inf.kids);
          more(inf, false, limit);
        }
        if (inf.kids) inf.kids.hidden = !on;
      }
      function more(inf, all, limit) {
        var node = inf.node, total = node.vals.length;
        var stop = all ? total : Math.min(total, inf.shown + CHUNK);
        if (limit !== undefined) stop = Math.min(stop, limit);
        if (inf.more) { inf.more.remove(); inf.more = null; }
        var frag = doc.createDocumentFragment();
        for (var j = inf.shown; j < stop; j++) frag.appendChild(row(child(node, j), inf, keyOf(node, j), inf.depth + 1));
        inf.shown = stop;
        if (stop < total) {
          var m = el('div', 'aj-more');
          m.style.setProperty('--d', inf.depth + 1);
          var next = el('button', 'aj-btn'), every = el('button', 'aj-btn');
          next.setAttribute('data-label', 'Show ' + Math.min(CHUNK, total - stop) + ' More');
          every.setAttribute('data-label', 'Show All ' + total);
          next.addEventListener('click', function () { more(inf, false); });
          every.addEventListener('click', function () { more(inf, true); });
          m.appendChild(next);
          m.appendChild(every);
          frag.appendChild(m);
          inf.more = m;
        }
        inf.kids.appendChild(frag);
      }
      function planned(root) {
        var want = new Set([root]), rows = 1 + Math.min(root.vals.length, CHUNK), level = [root];
        while (level.length) {
          var next = [];
          for (var a = 0; a < level.length; a++) {
            var nd = level[a], m = Math.min(nd.vals.length, CHUNK);
            for (var j = 0; j < m; j++) {
              var c = nd.vals[j];
              if (C.boxed(c) && c.vals.length) next.push(c);
            }
          }
          for (var b = 0; b < next.length; b++) {
            var cost = Math.min(next[b].vals.length, CHUNK);
            if (rows + cost > BUDGET) return want;
            rows += cost;
            want.add(next[b]);
          }
          level = next;
        }
        return want;
      }
      function buildTree() {
        if (rootInfo) return;
        plan = C.boxed(tree) && tree.vals.length ? planned(tree) : null;
        treeBox.appendChild(row(tree, null, undefined, 0));
        rootInfo = infos[0];
        plan = null;
      }
      function openAll(from) {
        var budget = ALL, stack = [from];
        while (stack.length && budget > 0) {
          var inf = stack.pop();
          if (!C.boxed(inf.node) || !inf.node.vals.length) continue;
          var count = Math.min(inf.node.vals.length, budget);
          open(inf, true, count);
          if (inf.shown < count) more(inf, true, count);
          budget -= count;
          var kids = inf.kids.children;
          for (var j = kids.length - 1; j >= 0; j--) {
            var id = kids[j].dataset.id;
            if (id !== undefined) stack.push(infos[+id]);
          }
        }
      }
      function shutAll() {
        for (var j = 1; j < infos.length; j++) if (infos[j].open) open(infos[j], false);
        open(rootInfo, true);
        if (selected && selected.parent) select(rootInfo);
      }
      function select(inf) {
        if (selected) selected.row.classList.remove('aj-sel');
        selected = inf;
        if (inf) inf.row.classList.add('aj-sel');
      }
      function infoAt(target) {
        var line = target && target.closest ? target.closest('.aj-line') : null;
        return line && treeBox.contains(line) ? infos[+line.parentNode.dataset.id] : null;
      }
      function visible() {
        var out = [], lines = treeBox.querySelectorAll('.aj-line');
        for (var j = 0; j < lines.length; j++) if (lines[j].offsetParent !== null) out.push(infos[+lines[j].parentNode.dataset.id]);
        return out;
      }
      treeBox.addEventListener('click', function (e) {
        if (e.target.closest('a')) return;
        var inf = infoAt(e.target);
        if (!inf) return;
        select(inf);
        if (!C.boxed(inf.node) || !inf.node.vals.length) return;
        if (e.target.closest('.aj-v') && !e.target.closest('.aj-sum')) return;
        if (String(getSelection()).length && !e.target.closest('.aj-tog')) return;
        if (e.altKey) { if (inf.open) { open(inf, false); } else { openAll(inf); } }
        else open(inf, !inf.open);
      });
      doc.addEventListener('keydown', function (e) {
        if (current !== 'tree' || !selected || e.metaKey || e.ctrlKey || e.altKey) return;
        var t = doc.activeElement;
        if (t && t !== body && t !== html && t.tagName !== 'BUTTON') return;
        var k = e.key, list, at;
        if (k === 'ArrowDown' || k === 'ArrowUp') {
          list = visible();
          at = list.indexOf(selected) + (k === 'ArrowDown' ? 1 : -1);
          if (at >= 0 && at < list.length) select(list[at]);
        } else if (k === 'ArrowRight') {
          if (C.boxed(selected.node) && selected.node.vals.length) {
            if (!selected.open) open(selected, true);
            else { list = visible(); select(list[list.indexOf(selected) + 1] || selected); }
          }
        } else if (k === 'ArrowLeft') {
          if (selected.open) open(selected, false);
          else if (selected.parent) select(selected.parent);
        } else return;
        e.preventDefault();
        selected.row.firstChild.scrollIntoView({ block: 'nearest' });
      });
      doc.addEventListener('beforecopy', function (e) {
        if (current === 'tree' && selected && getSelection().isCollapsed) e.preventDefault();
      });
      doc.addEventListener('copy', function (e) {
        if (current !== 'tree' || !selected || !getSelection().isCollapsed) return;
        e.clipboardData.setData('text/plain', C.value(selected.node));
        e.preventDefault();
      });
      doc.addEventListener('contextmenu', function (e) {
        if (!e.isTrusted || !relay) return;
        var inf = current === 'tree' ? infoAt(e.target) : null;
        if (inf) select(inf);
        relay.postMessage({ menu: inf ? { id: inf.id, path: C.path(keys(inf)) } : null });
      }, true);

      function paint(node, pad, out) {
        if (!C.boxed(node)) { out.appendChild(leaf(node, true)); return; }
        var o = node.k === 'o', n = node.vals.length;
        if (!n) { out.appendChild(doc.createTextNode(o ? '{}' : '[]')); return; }
        var inner = pad + '  ';
        out.appendChild(doc.createTextNode(o ? '{\n' : '[\n'));
        for (var j = 0; j < n; j++) {
          out.appendChild(doc.createTextNode(inner));
          if (o) {
            out.appendChild(el('span', 'aj-k', JSON.stringify(node.keys[j])));
            out.appendChild(doc.createTextNode(': '));
          }
          paint(node.vals[j], inner, out);
          out.appendChild(doc.createTextNode(j < n - 1 ? ',\n' : '\n'));
        }
        out.appendChild(doc.createTextNode(pad + (o ? '}' : ']')));
      }
      function buildPretty() {
        if (prettyBox.firstChild) return;
        if (raw.length > PAINT) { prettyBox.textContent = C.text(tree, '  '); return; }
        var frag = doc.createDocumentFragment();
        paint(tree, '', frag);
        prettyBox.appendChild(frag);
      }
      function notice(text, action, label) {
        note.textContent = text;
        if (action) {
          var b = el('button', 'aj-btn');
          b.setAttribute('data-label', label);
          b.addEventListener('click', action);
          note.appendChild(b);
        }
        note.hidden = false;
      }
      function show(mode, save) {
        if (mode !== 'raw') load();
        if (save && relay) relay.postMessage({ mode: mode });
        if (mode !== 'raw' && !tree) mode = 'raw';
        current = mode;
        if (error) {
          var w = C.where(raw, error.at);
          notice('Not valid JSON: ' + error.msg + ' at line ' + w.line + ', column ' + w.column + '. Shown as sent.');
          html.setAttribute('data-broadway-json-error', error.msg);
        } else if (big && !tree) {
          notice('This JSON is ' + bytes(raw.length) + ', so it is shown as sent.', function () {
            load();
            note.hidden = true;
            show('tree', false);
          }, 'Show Tree Anyway');
        } else {
          note.hidden = true;
        }
        if (mode === 'tree') buildTree();
        if (mode === 'pretty') buildPretty();
        pre.style.display = mode === 'raw' ? '' : 'none';
        treeBox.hidden = mode !== 'tree';
        prettyBox.hidden = mode !== 'pretty';
        expand.hidden = collapse.hidden = mode !== 'tree';
        for (var m in buttons) {
          buttons[m].setAttribute('aria-pressed', m === mode ? 'true' : 'false');
          buttons[m].disabled = m !== 'raw' && (!!error || (big && !tree));
        }
        html.setAttribute('data-broadway-json', mode);
      }

      window.__broadwayJSON = {
        value: function (id) { var inf = infos[id]; return inf ? C.value(inf.node) : null; },
        path: function (id) { var inf = infos[id]; return inf ? C.path(keys(inf)) : null; },
        raw: function () { return raw; },
        show: function (mode) { show(mode, false); return current; },
        rows: function () { return infos.length; },
        find: function (path) {
          for (var j = 0; j < infos.length; j++) if (C.path(keys(infos[j])) === path) return j;
          return -1;
        },
        open: function (id, on) { var inf = infos[id]; if (inf) open(inf, on !== false); return inf ? inf.open : null; },
        select: function (id) { var inf = infos[id]; if (inf) select(inf); return !!inf; }
      };
      show(big && wanted !== 'raw' ? 'raw' : wanted, false);
    })();
    """#
}
