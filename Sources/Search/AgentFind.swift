import AppKit
import WebKit

extension AgentPage {
    static let textHitsScript = walkBase + """

    var want = broadwayFlat(words, 200).toLowerCase();
    if (!want || !document.body) return { hits: [], count: 0 };
    function flat(el) { return broadwayFlat(el.innerText || '', 100000).toLowerCase(); }
    var found = [], unshown = window.innerWidth < 1;
    function legible(el) {
      if (broadwayLegible(el)) return true;
      if (!unshown || !el.getClientRects().length || el.hidden || el.getAttribute('aria-hidden') === 'true') return false;
      var s = getComputedStyle(el);
      if (s.display === 'none' || s.visibility !== 'visible' || parseFloat(s.opacity) < 0.1) return false;
      var at = broadwayGround(el);
      return !broadwayFaint(el, s, at.alpha, at.ground);
    }
    function dig(el) {
      var deeper = false;
      for (var c = el.firstElementChild; c; c = c.nextElementSibling) {
        if (/^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|TITLE)$/.test(c.tagName)) continue;
        if (flat(c).indexOf(want) < 0) continue;
        deeper = true;
        if (found.length < 40) dig(c);
      }
      if (!deeper && found.length < 40 && legible(el)) found.push(el);
    }
    if (flat(document.body).indexOf(want) >= 0) dig(document.body);
    var walked = broadwayWalk(document.body, { cap: 5000 });
    var controls = walked.rows.filter(function (r) { return r.item && !r.landmark && r.item.role !== 'heading' && r.item.role !== 'scrollable' && !r.item.closed && !broadwayTold.test(r.item.role); });
    function gap(a, b) {
      var dx = Math.max(0, a.left - b.right, b.left - a.right), dy = Math.max(0, a.top - b.bottom, b.top - a.bottom);
      return Math.sqrt(dx * dx + dy * dy);
    }
    function closest(list, box) {
      var best = null, least = Infinity;
      list.forEach(function (r) { var d = gap(r.el.getBoundingClientRect(), box); if (d < least) { least = d; best = r; } });
      return best;
    }
    function nearest(el) {
      var box = el.getBoundingClientRect();
      var holding = controls.filter(function (r) { return r.el.contains(el); });
      if (holding.length) return holding[holding.length - 1];
      for (var up = el, depth = 0; up && up !== document.documentElement && depth < 6; up = up.parentElement, depth++) {
        var inside = controls.filter(function (r) { return up.contains(r.el); });
        if (inside.length) return closest(inside, box);
      }
      return closest(controls, box);
    }
    var hits = found.slice(0, most || 5).map(function (el) {
      var text = broadwayFlat(el.innerText, 2000);
      if (text.length > 160) {
        var at = Math.max(0, text.toLowerCase().indexOf(want) - 60);
        text = (at ? '…' : '') + text.slice(at, at + 160) + (at + 160 < text.length ? '…' : '');
      }
      var hit = { text: text, in_view: broadwayInView(el) }, near = nearest(el);
      if (near) { broadwayTell(near.item.ref); hit.near = { ref: near.item.ref, role: near.item.role, name: near.item.name }; }
      return hit;
    });
    return { hits: hits, count: found.length, doc: broadwayState().doc, loading: document.readyState !== 'complete' };
    """
}

extension BrowserToolbox {
    struct TextHits {
        var hits: [[String: Any]] = []
        var count = 0
        var loading = false
    }

    func textHits(_ words: String, tab: Tab, most: Int = 5) async -> TextHits {
        var found = TextHits()
        var places: [(name: String?, frame: WKFrameInfo?)] = [(nil, nil)]
        places += frameNames(tab).filter { sameSite(tab, $0.frame) }.map { ($0.name, $0.frame) }
        for place in places where found.hits.count < most {
            guard let said = await timed(tab, AgentPage.textHitsScript, ["words": words, "most": most - found.hits.count], in: place.frame, seconds: 5) as? [String: Any] else { continue }
            if place.frame == nil {
                found.loading = said["loading"] as? Bool == true
                if let doc = said["doc"] as? String { AgentRefBook.note(tab, doc: doc, title: tab.title, next: nil) }
            }
            found.count += said["count"] as? Int ?? 0
            for hit in said["hits"] as? [[String: Any]] ?? [] {
                var hit = hit
                if let name = place.name, var near = hit["near"] as? [String: Any] {
                    near["ref"] = "\(name).\(near["ref"] as? String ?? "")"
                    hit["near"] = near
                }
                found.hits.append(hit)
            }
        }
        return found
    }

    static func hitLine(_ hit: [String: Any]) -> String {
        var line = "text \"\(AgentChange.cell(hit["text"] as? String ?? "", most: 200))\""
        line += hit["in_view"] as? Bool == true ? "  (in view)" : "  (out of view)"
        if let near = hit["near"] as? [String: Any] {
            line += "  near @\(near["ref"] as? String ?? "") \(near["role"] as? String ?? "") \"\(AgentChange.cell(near["name"] as? String ?? "", most: 60))\""
        }
        return line
    }

    struct Miss {
        var hint: String?
        var data: [String: Any] = [:]
    }

    func miss(_ target: AgentTarget, tab: Tab, skipped: [String], silent: [String], textChecked: Bool = false) async -> Miss {
        var parts: [String] = []
        var data: [String: Any] = ["website": true]
        let words = target.words ?? target.label ?? ""
        if !textChecked, !words.isEmpty, target.roles.isEmpty, target.label == nil {
            let text = await textHits(words, tab: tab, most: 1)
            if text.count > 0 {
                parts.append("\"\(AgentChange.cell(words))\" is text on the page, not the name of a control. broadway find \"\(AgentChange.cell(words))\" shows the controls near it.")
                data["in_text"] = true
            }
        }
        if !words.isEmpty, let items = await everything(tab) {
            let named = items.compactMap { item -> AgentNear.Named? in
                guard let ref = item["ref"] as? String, let name = item["name"] as? String, !name.isEmpty else { return nil }
                let role = item["role"] as? String ?? ""
                if !target.roles.isEmpty, !target.roles.contains(role) { return nil }
                return (ref, role, name)
            }
            if let shut = items.first(where: { $0["closed"] as? Bool == true })?["ref"] as? String {
                parts.append("Part of this page is closed to reading at @\(shut), so find can't see inside it. Look with broadway shot, then act there with broadway click --at X,Y.")
                data["closed"] = shut
            }
            let close = AgentNear.closest(words, among: named)
            if !close.isEmpty {
                parts.append("Closest names: " + close.map(AgentNear.line).joined(separator: ", "))
                data["closest"] = close.map { ["ref": $0.ref, "role": $0.role, "name": $0.name] }
            }
        }
        if tab.loading {
            parts.append("The page is still loading. broadway wait \"\(AgentChange.cell(words.isEmpty ? "TEXT" : words))\" waits for it.")
            data["loading"] = true
        }
        if !skipped.isEmpty {
            let hosts = Array(Set(skipped)).sorted()
            parts.append("\(skipped.count == 1 ? "An embedded frame" : "\(skipped.count) embedded frames") from \(hosts.joined(separator: ", ")) \(skipped.count == 1 ? "was" : "were") not searched. Add --frames to look there too.")
            data["unsearched"] = hosts
        }
        if !silent.isEmpty {
            parts.append("A frame from \(Array(Set(silent)).sorted().joined(separator: ", ")) gave no answer")
            data["silent"] = Array(Set(silent)).sorted()
        }
        if parts.isEmpty { parts.append("broadway snapshot gives a fresh look") }
        let hint = parts.count == 1 ? parts[0] : parts.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
        return Miss(hint: hint, data: data)
    }
}
