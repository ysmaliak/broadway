import AppKit
import WebKit

struct PickedText: Equatable {
    enum Kind: String, Codable, CaseIterable {
        case page, box, code
    }

    var text: String
    var kind: Kind
    var editable: Bool
    var box: CGRect
    var family: String
    var size: CGFloat
}

enum PageSelection {
    static let secretCheck = """
    function broadwaySecret(el) {
      if (!el || el.nodeType !== 1) return false;
      if (el.__broadwaySecret) return true;
      var type = (el.getAttribute('type') || '').toLowerCase();
      var fill = (el.getAttribute('autocomplete') || '').toLowerCase();
      var name = ((el.getAttribute('name') || '') + ' ' + (el.id || '') + ' ' + (el.getAttribute('aria-label') || '') + ' ' + (el.getAttribute('placeholder') || '')).toLowerCase();
      if (type === 'password') return el.__broadwaySecret = true;
      if (fill.indexOf('cc-') >= 0 || fill.indexOf('password') >= 0 || fill.indexOf('one-time-code') >= 0) return true;
      var said = name;
      if (el.labels) for (var l = 0; l < el.labels.length; l++) said += ' ' + (el.labels[l].textContent || '');
      var group = el.closest && el.closest('fieldset');
      var legend = group && group.querySelector('legend');
      if (legend) said += ' ' + (legend.textContent || '');
      said = said.toLowerCase();
      if (/(seed|recovery|secret|backup|mnemonic).?(phrase|words)|\\bmnemonic\\b|private.?key/.test(said)) return el.__broadwaySecret = true;
      var held = typeof el.value === 'string' ? el.value : (el.isContentEditable ? el.textContent || '' : '');
      if (/-----BEGIN [A-Z ]*PRIVATE KEY-----/.test(held)) return el.__broadwaySecret = true;
      return /card.?(num|no)|cardnumber|cc.?num|\\bcvc\\b|\\bcvv\\b|security.?code|pass.?word|passwd|\\bpwd\\b|passcode|passphrase|\\bpin\\b|\\bssn\\b|social.?security|api.?key|\\btoken\\b|\\bsecret\\b|\\botp\\b|one.?time|verification.?code|\\biban\\b|routing.?number/.test(name);
    }
    """

    static let readScript = """
    \(secretCheck)
    var el = document.activeElement, text = '', box = null, editable = false, kind = 'page', ground = null;
    var typing = el && (el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && /^(text|search|url|email|tel|)$/.test((el.getAttribute('type') || '').toLowerCase())));
    if (broadwaySecret(el)) return null;
    if (typing) {
      var start = el.selectionStart || 0, end = el.selectionEnd || 0;
      text = el.value.substring(start, end);
      if (!text) return null;
      box = el.getBoundingClientRect();
      editable = !el.readOnly && !el.disabled;
      kind = 'box';
      ground = el;
      window.__broadwayMark = { el: el, start: start, end: end };
    } else {
      var picked = getSelection();
      if (!picked || picked.isCollapsed || !picked.rangeCount) return null;
      text = picked.toString();
      if (!text.trim()) return null;
      var range = picked.getRangeAt(0).cloneRange();
      box = range.getBoundingClientRect();
      var node = range.commonAncestorContainer;
      ground = node.nodeType === 1 ? node : node.parentElement;
      if (ground && ground.closest('[contenteditable=""],[contenteditable="true"],[contenteditable="plaintext-only"]')) {
        editable = true;
        kind = 'box';
      } else if (ground && ground.closest('pre,code')) {
        kind = 'code';
      }
      window.__broadwayMark = { range: range };
    }
    var look = ground ? getComputedStyle(ground) : null;
    return { text: text.slice(0, 40000), kind: kind, editable: editable,
             x: box.left, y: box.top, width: box.width, height: box.height,
             family: look ? look.fontFamily : '', size: look ? parseFloat(look.fontSize) : 14 };
    """

    static let replaceScript = """
    var mark = window.__broadwayMark;
    if (!mark) return false;
    if (mark.el) {
      if (!document.contains(mark.el)) return false;
      mark.el.focus();
      mark.el.setSelectionRange(mark.start, mark.end);
      if (!document.execCommand('insertText', false, text)) {
        mark.el.setRangeText(text, mark.start, mark.end, 'end');
        mark.el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
      }
    } else {
      var picked = getSelection();
      picked.removeAllRanges();
      picked.addRange(mark.range);
      if (!document.execCommand('insertText', false, text)) return false;
    }
    window.__broadwayMark = null;
    return true;
    """

    static let boxScript = """
    \(secretCheck)
    var el = document.activeElement;
    if (!el || broadwaySecret(el)) return false;
    var input = el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && /^(text|search|url|email|tel|)$/.test((el.getAttribute('type') || '').toLowerCase()));
    if (!input && !el.isContentEditable) return false;
    if (el.readOnly || el.disabled) return false;
    el.focus();
    if (document.execCommand('insertText', false, text)) return true;
    if (input) {
      el.setRangeText(text, el.selectionStart || 0, el.selectionEnd || 0, 'end');
      el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
      return true;
    }
    return false;
    """

    @MainActor
    static func run(_ tab: Tab, _ script: String, _ arguments: [String: Any] = [:], in frame: WKFrameInfo? = nil) async -> Any? {
        guard let web = tab.built else { return nil }
        guard frame != nil else {
            return await withCheckedContinuation { done in
                web.callAsyncJavaScript(script, arguments: arguments, in: frame, in: Web.world) { result in
                    done.resume(returning: try? result.get())
                }
            }
        }
        return await withCheckedContinuation { (done: CheckedContinuation<Any?, Never>) in
            var answered = false
            web.callAsyncJavaScript(script, arguments: arguments, in: frame, in: Web.world) { result in
                guard !answered else { return }
                answered = true
                done.resume(returning: try? result.get())
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard !answered else { return }
                answered = true
                done.resume(returning: nil)
            }
        }
    }

    @MainActor
    static func read(_ tab: Tab) async -> PickedText? {
        guard let found = await run(tab, readScript) as? [String: Any], let text = found["text"] as? String else { return nil }
        let rect = CGRect(x: found["x"] as? Double ?? 0, y: found["y"] as? Double ?? 0,
                          width: found["width"] as? Double ?? 0, height: found["height"] as? Double ?? 0)
        let scale = tab.built?.pageZoom ?? 1
        var box = rect.applying(CGAffineTransform(scaleX: scale, y: scale))
        if let web = tab.built {
            let spot = web.convert(NSPoint(x: box.minX, y: web.isFlipped ? box.minY : web.bounds.height - box.minY), to: nil)
            if let height = web.window?.contentView?.bounds.height {
                box.origin = CGPoint(x: spot.x, y: height - spot.y)
            }
        }
        return PickedText(text: text, kind: PickedText.Kind(rawValue: found["kind"] as? String ?? "") ?? .page,
                          editable: found["editable"] as? Bool ?? false, box: box,
                          family: found["family"] as? String ?? "", size: CGFloat(found["size"] as? Double ?? 14) * scale)
    }

    @MainActor
    static func replace(_ text: String, tab: Tab) async -> Bool {
        await run(tab, replaceScript, ["text": text]) as? Bool ?? false
    }

    @MainActor
    static func putInBox(_ text: String, tab: Tab) async -> Bool {
        await run(tab, boxScript, ["text": text]) as? Bool ?? false
    }
}
