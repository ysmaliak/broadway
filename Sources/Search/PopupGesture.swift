import WebKit

/// One new browsing context for a recent real interaction. WebKit's form
/// submission path still uses its synchronous gesture indicator; after a
/// fetch, a POST to _blank can be refused even while userActivation is active.
/// Search keeps the short-lived permission outside the page instead.
struct PopupGesture {
    private var origin: String?
    private var recorded = false
    private var time: TimeInterval = 0
    private var consumed = false
    private var input = false
    private var menu = false
    /// Which interaction this is, kept across clear(), and the tab the
    /// page's own window for it became (see opened(_:) and claim()).
    private var serial = 0
    private var made: (serial: Int, tab: UUID)?
    private(set) var hits: [PopupHit] = []
    private(set) var spawn: PopupSpawn?

    mutating func record(origin: String?, kind: String, hit: PopupHit? = nil, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // Click and contextmenu follow mousedown (or keyboard activation). They must not
        // grant a second window after the first event already opened one,
        // even when the button was held for most of the activation window.
        if kind != "input", input, self.origin == origin, now >= time, now - time <= 5 {
            if kind == "menu" { menu = true }
            if let hit { hits.append(hit) }
            return
        }
        self.origin = origin
        serial += 1
        hits = hit.map { [$0] } ?? []
        recorded = true
        time = now
        consumed = false
        input = kind != "click"
        menu = kind == "menu"
    }

    mutating func take(origin: String?, mainFrame: Bool = false, patient: Bool = false,
                       now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        // Activation in an iframe also activates its top-level document.
        // It does not activate an unrelated third-party sibling frame.
        // Opaque origins have no tuple to compare. They can activate the
        // top-level document, never another opaque (or named) subframe.
        let patience = patient && PopupGuard.seen(hits) ? PopupGuard.signInPatience : 5
        guard recorded, (mainFrame || (origin != nil && self.origin == origin)),
              !consumed, now >= time, now - time <= patience else { return false }
        consumed = true
        return true
    }

    /// Whether a refused window came from an interaction that already
    /// had its one: a second window for the same click, or a page's own
    /// beside the tab Search opened for a ⌘-click (see claim()). That one
    /// is the duplicate one click must not make, not a pop-up to offer.
    func spent(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        recorded && consumed && now >= time && now - time <= 5
    }

    mutating func clear() {
        let serial = serial
        let spawn = spawn
        self = PopupGesture()
        self.serial = serial
        self.spawn = spawn
    }

    /// The window take() just granted became this tab.
    mutating func opened(_ tab: UUID, sized: Bool = false, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        made = (serial, tab)
        spawn = PopupSpawn(serial: serial, at: now, tab: tab, refused: false, sized: sized)
    }

    mutating func refused(sized: Bool, reason: PopupRefusal? = nil, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        spawn = PopupSpawn(serial: serial, at: now, tab: nil, refused: true, sized: sized, reason: reason)
    }

    func tabUnder(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> PopupSpawn? {
        guard let spawn, spawn.serial == serial, now >= spawn.at, now - spawn.at <= PopupGuard.tabUnderWindow else { return nil }
        return spawn
    }

    mutating func dropSpawn() {
        spawn = nil
    }

    /// A tab Search opens itself for a click — ⌘-click, the middle button.
    /// One click makes one tab: a page that also calls window.open from the
    /// same click (Gmail's links do, beside their own target=_blank) gets no
    /// second one, whichever comes first. Returns the tab the page's window
    /// already became for this interaction, if it came first; otherwise the
    /// interaction is spent, so a window.open after this is refused.
    mutating func claim(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> UUID? {
        guard recorded, now >= time, now - time <= 5 else { return nil }
        if consumed, let made, made.serial == serial { return made.tab }
        consumed = true
        return nil
    }

    /// A native menu can remain open beyond the activation window. Keep the
    /// recorded frame and one-use limit when its action finally reaches WebKit.
    mutating func menuClosed(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard menu else { return }
        menu = false
        guard recorded, !consumed, now >= time else { return }
        time = now
    }

    static func origin(_ info: WKFrameInfo) -> String? {
        let origin = info.securityOrigin
        if let key = originKey(scheme: origin.protocol, host: origin.host, port: origin.port) { return key }
        // A sandboxed frame has an opaque origin: no tuple, so its own click
        // never matched the link it was on, and every target=_blank link in
        // it did nothing (answers some AI chats draw in a sandbox). It is
        // keyed by its own document instead, never matching a frame with a
        // tuple, nor an opaque top-level page (that one goes by mainFrame).
        guard !info.isMainFrame, let url = info.request.url?.absoluteString, !url.isEmpty else { return nil }
        return "opaque " + url
    }

    static func originKey(scheme: String, host: String, port: Int) -> String? {
        guard !scheme.isEmpty, !host.isEmpty else { return nil }
        return "\(scheme)://\(host):\(port)"
    }
}

/// Only the isolated Search world has this handler. Website code cannot
/// call it or replace its listener; dispatched events do not grant windows.
final class PopupGestureRelay: NSObject, WKScriptMessageHandler {
    static let name = "officePopupGesture"

    static let script = """
    (() => {
      const keys = new Set();
      const media = 'video,audio,iframe,canvas,embed,object';
      const shown = media + ',img,svg,picture,input,select,textarea,button';
      const control = 'a[href],button,input,select,textarea,label,summary,[onclick],[role=button],[role=link],' +
        '[role=menuitem],[role=tab],[role=checkbox],[role=switch],[role=option],[tabindex]:not([tabindex="-1"])';
      const named = /(^|[^a-z])(play|pause|close|skip|watch|download|continue|start)/i;
      let last = null;
      function alpha(color) {
        if (!color || color === 'transparent') return 0;
        const parts = color.slice(color.indexOf('(') + 1, color.lastIndexOf(')')).split(/[ ,/]+/).filter(Boolean);
        const at = color.startsWith('rgb') ? 3 : 4;
        if (parts.length <= at) return 1;
        const value = parts[at];
        return value.endsWith('%') ? parseFloat(value) / 100 : parseFloat(value);
      }
      function painted(style) {
        if (alpha(style.backgroundColor) > 0.1 || style.backgroundImage !== 'none' || style.boxShadow !== 'none') return true;
        return ['Top', 'Right', 'Bottom', 'Left'].some(side => parseFloat(style['border' + side + 'Width']) > 0 &&
          style['border' + side + 'Style'] !== 'none' && alpha(style['border' + side + 'Color']) > 0.1);
      }
      function shows(node) {
        if (node.matches(shown) || node instanceof SVGElement) return true;
        const style = getComputedStyle(node);
        if (painted(style)) return true;
        for (const at of ['::before', '::after']) {
          const pseudo = getComputedStyle(node, at);
          const content = pseudo.content;
          if (content && content !== 'none' && content !== 'normal' && (content !== '""' || painted(pseudo))) return true;
        }
        if (alpha(style.color) <= 0.1) return false;
        return [...node.childNodes].some(child => child.nodeType === 3 && child.data.trim());
      }
      const up = node => node.assignedSlot || node.parentElement || (node.parentNode && node.parentNode.host) || null;
      const within = (node, selector) => {
        for (let at = node; at; at = up(at)) if (at.matches(selector)) return at;
        return null;
      };
      const holds = (outer, inner) => {
        for (let at = inner; at; at = up(at)) if (at === outer) return true;
        return false;
      };
      const small = node => {
        const box = node.getBoundingClientRect();
        return box.width * box.height <= 60000;
      };
      const pointer = node => getComputedStyle(node).cursor === 'pointer';
      function stack(x, y) {
        const out = [];
        const roots = new Set();
        const add = scope => {
          for (const node of scope.elementsFromPoint(x, y)) {
            if (node.getRootNode() !== scope) continue;
            if (node.shadowRoot && !roots.has(node.shadowRoot)) {
              roots.add(node.shadowRoot);
              add(node.shadowRoot);
            }
            out.push(node);
          }
        };
        add(document);
        return out;
      }
      function facts(e) {
        const first = e.composedPath()[0];
        const hit = first && first.nodeType === 1 ? first : e.target;
        if (!hit || hit.nodeType !== 1) return null;
        const fades = new Map();
        const fade = node => {
          if (!node || node.nodeType !== 1) return 1;
          if (!fades.has(node)) fades.set(node, parseFloat(getComputedStyle(node).opacity) * fade(up(node)));
          return fades.get(node);
        };
        const root = node => node === document.documentElement || node === document.body;
        const sized = node => { const box = node.getBoundingClientRect(); return box.width > 1 && box.height > 1; };
        const button = node => !root(node) && small(node) &&
          ![...node.querySelectorAll(media)].some(inner => sized(inner) && fade(inner) >= 0.1);
        let t = hit;
        let masked = false;
        if (fade(t) < 0.1) {
          let shown = up(t);
          while (shown && fade(shown) < 0.1) shown = up(shown);
          const box = shown && shown.getBoundingClientRect();
          const under = box && e.clientX >= box.left && e.clientX <= box.right && e.clientY >= box.top && e.clientY <= box.bottom;
          if (under && button(shown)) {
            if (within(shown, control) || pointer(shown)) t = shown;
            else masked = shows(shown) || [...shown.querySelectorAll('*')].some(inner => sized(inner) && fade(inner) >= 0.1 && shows(inner));
          }
        }
        const style = getComputedStyle(t);
        const link = within(hit, 'a[href]');
        const href = link && /^https?:$/.test(link.protocol) &&
          link.href.split('#')[0] !== location.href.split('#')[0] ? link.href : '';
        let over = '';
        if (!root(t)) {
          const seen = stack(e.clientX, e.clientY).find(node => !root(node) && fade(node) >= 0.1 && shows(node));
          if (!seen) {
            over = 'nothing';
          } else if (!holds(seen, t) && !holds(t, seen)) {
            const mine = within(t, control);
            if (!(mine && mine === within(seen, control) && button(mine))) {
              const near = [seen, up(seen), up(seen) && up(up(seen))].filter(Boolean);
              const words = node => [node.id, node.getAttribute('class'), node.getAttribute('aria-label'), node.getAttribute('title')].join(' ');
              over = within(seen, media) ? 'media'
                : within(seen, control) || near.some(node => named.test(words(node))) ? 'control' : 'content';
            }
          }
        }
        const box = t.getBoundingClientRect();
        const wide = Math.max(0, Math.min(box.right, innerWidth) - Math.max(box.left, 0));
        const high = Math.max(0, Math.min(box.bottom, innerHeight) - Math.max(box.top, 0));
        const sealed = t.localName.includes('-') && t.matches(':defined') && !t.shadowRoot && small(t);
        return {
          fade: fade(t), hidden: style.visibility !== 'visible', over,
          cover: innerWidth && innerHeight ? (wide * high) / (innerWidth * innerHeight) : 0,
          active: !!(within(t, control) || style.cursor === 'pointer' || sealed), link: href, masked,
        };
      }
      function track(e) {
        if (e.type === 'mousedown') {
          last = { t: e.target, x: e.clientX, y: e.clientY, clicked: false, pending: false };
          return;
        }
        if (!last) return;
        if (e.target !== last.t) { last = null; return; }
        last.clicked = true;
        if (last.pending) setTimeout(pass);
      }
      function pass() {
        const hit = last;
        last = null;
        if (!hit || !hit.t || !hit.t.style) return;
        let block = hit.t;
        let under = null;
        for (let i = 0; i < 4 && block && block !== document.body && block !== document.documentElement; i++) {
          block.style.setProperty('pointer-events', 'none', 'important');
          under = document.elementFromPoint(hit.x, hit.y);
          block = under && under.contains(hit.t) ? under : null;
        }
        if (!under || block || under.contains(hit.t)) return;
        const base = { bubbles: true, cancelable: true, composed: true, view: window, clientX: hit.x, clientY: hit.y, button: 0 };
        for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
          const init = Object.assign({}, base, { buttons: type.endsWith('down') ? 1 : 0 });
          under.dispatchEvent(type.startsWith('pointer')
            ? new PointerEvent(type, Object.assign(init, { pointerType: 'mouse', isPrimary: true }))
            : new MouseEvent(type, init));
        }
      }
      globalThis.broadwayPopupPass = () => {
        if (!last) return false;
        if (last.clicked) setTimeout(pass); else last.pending = true;
        return true;
      };
      function note(e) {
        if (!e.isTrusted) return;
        if (e.type === 'keydown' && (e.key === 'Escape' ||
            ['Shift', 'Control', 'Alt', 'Meta'].includes(e.key))) return;
        if (e.type === 'keydown') keys.add(e.code || e.key);
        if (e.repeat) return;
        // Enter can produce trusted clicks while held; those clicks have no
        // repeat flag. The initial keydown already supplied their one grant.
        if (e.type === 'click' && e.detail === 0 && keys.size) return;
        let hit = null;
        if (e.button === 0 && (e.type === 'mousedown' || (e.type === 'click' && e.detail > 0))) {
          try { hit = facts(e); } catch (error) { hit = null; }
          track(e);
        }
        window.webkit.messageHandlers.officePopupGesture.postMessage({
          kind: e.type === 'click' ? 'click' : e.type === 'contextmenu' ? 'menu' : 'input', hit });
      }
      addEventListener('mousedown', note, true);
      addEventListener('keydown', note, true);
      addEventListener('click', note, true);
      addEventListener('contextmenu', note, true);
      addEventListener('keyup', e => { if (e.isTrusted) keys.delete(e.code || e.key); }, true);
      addEventListener('blur', e => { if (e.isTrusted && e.target === window) keys.clear(); }, true);
    })();
    """

    @MainActor static func install(on controller: WKUserContentController) {
        controller.add(PopupGestureRelay(), contentWorld: Web.world, name: name)
    }

    @MainActor static var userScript: WKUserScript {
        WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
    }

    // Extension pages share a controller, so its most recently installed
    // relay must route by the message's view, not by the tab that made it.
    @MainActor static func tab(for webView: WKWebView) -> Tab? {
        (webView.navigationDelegate as? Browser)?.popupTab(for: webView)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any]
        guard let kind = (body?["kind"] ?? message.body) as? String, ["input", "click", "menu"].contains(kind) else { return }
        let hit = PopupHit(body?["hit"] ?? nil)
        MainActor.assumeIsolated {
            guard let webView = message.webView, let tab = Self.tab(for: webView) else { return }
            tab.popupGesture.record(origin: PopupGesture.origin(message.frameInfo), kind: kind, hit: hit)
        }
    }
}
