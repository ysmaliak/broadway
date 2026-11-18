import AppKit
import WebKit

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
}
