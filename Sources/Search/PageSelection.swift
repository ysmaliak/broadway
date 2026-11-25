import AppKit
import WebKit

enum PageSelection {
    static let secretCheck = """
    function broadwaySecretWords(text) {
      var words = String(text || '').replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2').toLowerCase().replace(/[^\\p{L}\\p{N}]+/gu, ' ').trim();
      if (!words) return false;
      var secret = /card ?num|cardnumber|card ?no\\b|cc ?num|\\b(cvc|cvv|csc)2?\\b|security ?code|pass ?word|passwd|\\bpwd\\b|pass ?code|pass ?phrase|\\bpin\\b|\\bssn\\b|social ?security|api ?key|\\btoken\\b|\\bsecret\\b|\\botp\\b|one ?time(?! ?(payments?|purchases?|donations?|gifts?|fees?|charges?|amount|price|cost|contributions?|orders?|offers?|subscriptions?|top ?up)\\b)|verification ?code|\\b(recovery|backup|authentication|auth|two factor|2fa|mfa|sms|login|access) ?codes?\\b|\\biban\\b|routing ?(num|no\\b)/g;
      var about = /^(names?|labels?|titles?|descriptions?|notes?|nicknames?|alias|type|scopes?|expiry|expires|expiration|amount|symbol)$/;
      var naming = /(^| )(name|label|title|description|note|nickname|alias) (of|for) (the |this |your |a |an |new )?$/;
      var pinned = /^(to|it|this|that|on|post|posts|message|tab|location|board|item|items|chat)$/;
      var found;
      while ((found = secret.exec(words))) {
        var after = words.slice(found.index + found[0].length);
        var next = (after.match(/^ ?([\\p{L}\\p{N}]+)/u) || [])[1] || '';
        var then = (after.replace(/^ ?[\\p{L}\\p{N}]+/u, '').match(/^ ?([\\p{L}\\p{N}]+)/u) || [])[1] || '';
        var typing = next === 'type' && /^(or|and|here|in|into|it|your|the|a|an|below|to)$/.test(then);
        if (about.test(next) && !typing || naming.test(words.slice(0, found.index))) continue;
        if (found[0] === 'pin' && pinned.test(next)) continue;
        return true;
      }
      return false;
    }
    function broadwaySecret(el) {
      if (!el || el.nodeType !== 1) return false;
      if (el.__broadwaySecret) return true;
      var type = (el.getAttribute('type') || '').toLowerCase();
      var fill = (el.getAttribute('autocomplete') || '').toLowerCase();
      var sources = [el.getAttribute('name') || '', el.id || '', el.getAttribute('aria-label') || '', el.getAttribute('placeholder') || ''];
      if (type === 'password') return el.__broadwaySecret = true;
      if (fill.indexOf('cc-') >= 0 || fill.indexOf('password') >= 0 || fill.indexOf('one-time-code') >= 0) return true;
      var said = sources.join(' ');
      if (el.labels) for (var l = 0; l < el.labels.length; l++) said += ' ' + (el.labels[l].textContent || '');
      var group = el.closest && el.closest('fieldset');
      var legend = group && group.querySelector('legend');
      if (legend) said += ' ' + (legend.textContent || '');
      said = said.toLowerCase();
      if (/(seed|recovery|secret|backup|mnemonic).?(phrase|words)|\\bmnemonic\\b|private.?key/.test(said)) return el.__broadwaySecret = true;
      var held = typeof el.value === 'string' ? el.value : (el.isContentEditable ? el.textContent || '' : '');
      if (/-----BEGIN [A-Z ]*PRIVATE KEY-----/.test(held)) return el.__broadwaySecret = true;
      if (el.localName === 'button' || /^(checkbox|radio|submit|button|reset|image|range|color|file)$/.test(type)) return false;
      if (!(el.matches && el.matches('input,textarea,select')) && !el.isContentEditable) {
        return /card.?(num|no)|cardnumber|cc.?num|\\bcvc\\b|\\bcvv\\b|security.?code|pass.?word|passwd|\\bpwd\\b|passcode|passphrase|\\bpin\\b|\\bssn\\b|social.?security|api.?key|\\btoken\\b|\\bsecret\\b|\\botp\\b|one.?time|verification.?code|\\biban\\b|routing.?number/.test(sources.join(' ').toLowerCase());
      }
      if (broadwaySecretWords(sources.join(' '))) return true;
      for (var s = 0; s < sources.length; s++) if (broadwaySecretWords(sources[s])) return true;
      return false;
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
