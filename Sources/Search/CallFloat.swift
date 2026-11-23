import AppKit
import Combine
import Observation
import WebKit

enum CallButtons {
    struct Status: Equatable {
        var mic: Bool?
        var camera: Bool?
        var leaves = false
    }

    enum Key: Equatable {
        case mic, camera, leave
    }

    static func keys(_ status: Status) -> [Key] {
        (status.mic == nil ? [] : [.mic]) + (status.camera == nil ? [] : [.camera]) + (status.leaves ? [.leave] : [])
    }

    static let mic = [
        "[aria-label^='Turn off microphone']", "[aria-label^='Turn on microphone']",
        "#microphone-button", "button.join-audio-container__btn",
        "[data-qa='huddle_mini_player_mute_button']",
    ]
    static let camera = [
        "[aria-label^='Turn off camera']", "[aria-label^='Turn on camera']",
        "#video-button", "button.send-video-container__btn",
        "[data-qa='huddle_mini_player_video_button']",
    ]
    static let leave = [
        "[aria-label='Leave call']", "#hangup-button", "button.footer__leave-btn",
        "[data-qa='huddle_mini_player_leave_button']",
    ]

    private static func list(_ selectors: [String]) -> String {
        "[" + selectors.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    private static let finding = """
    function find(list) {
      for (var i = 0; i < list.length; i++) { var el = document.querySelector(list[i]); if (el) return el; }
      return null;
    }
    function on(el) {
      if (!el) return null;
      var muted = el.getAttribute('data-is-muted');
      if (muted !== null) return muted === 'false';
      var word = (el.getAttribute('aria-label') || '').toLowerCase();
      if (/^(turn off|mute|stop)/.test(word)) return true;
      if (/^(turn on|unmute|start)/.test(word)) return false;
      return null;
    }
    """

    static let read = """
    (function () {
      \(finding)
      return JSON.stringify({
        mic: on(find(\(list(mic)))),
        camera: on(find(\(list(camera)))),
        leave: !!find(\(list(leave)))
      });
    })()
    """

    static func press(_ selectors: [String]) -> String {
        """
        (function () {
          \(finding)
          var el = find(\(list(selectors)));
          if (!el) return false;
          el.click();
          setTimeout(function () {
            var sure = document.querySelector('.leave-meeting-options__btn');
            if (sure) sure.click();
          }, 300);
          return true;
        })()
        """
    }

    static func status(_ text: String?, mic nativeMic: WKMediaCaptureState, camera nativeCamera: WKMediaCaptureState) -> Status {
        var found = Status(mic: native(nativeMic), camera: native(nativeCamera))
        guard let data = text?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return found }
        if let mic = object["mic"] as? Bool { found.mic = mic }
        if let camera = object["camera"] as? Bool { found.camera = camera }
        found.leaves = object["leave"] as? Bool ?? false
        return found
    }

    private static func native(_ state: WKMediaCaptureState) -> Bool? {
        switch state {
        case .active: return true
        case .muted: return false
        default: return nil
        }
    }
}

enum CallKey: Equatable {
    case mic, camera, back, away

    static func read(code: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> Self? {
        let flags = flags.intersection([.command, .control, .option, .shift])
        if flags == .command {
            switch characters?.lowercased() {
            case "d": return .mic
            case "e": return .camera
            default: return nil
            }
        }
        guard flags.isEmpty else { return nil }
        switch code {
        case 36, 76: return .back
        case 53: return .away
        default: return nil
        }
    }
}

struct CallAway: Equatable {
    static let patience = 3

    private(set) var tab: UUID?
    private var quiet = 0

    func keeps(_ id: UUID) -> Bool { tab == id }

    mutating func put(_ id: UUID) {
        tab = id
        quiet = 0
    }

    mutating func heard(onCall: Bool) {
        guard tab != nil else { return }
        quiet = onCall ? 0 : quiet + 1
        if quiet >= Self.patience { self = CallAway() }
    }

    mutating func gone() { self = CallAway() }
}

enum CallTiles {
    static func style(_ room: NSEdgeInsets, corner: CGFloat) -> String {
        """
        html[data-broadway-tiles], html[data-broadway-tiles] body { background: #000 !important; overflow: hidden !important; }
        [data-broadway-tiles-path] { visibility: visible !important; background: transparent !important; box-shadow: none !important; \
        transform: none !important; filter: none !important; \
        backdrop-filter: none !important; perspective: none !important; contain: none !important; will-change: auto !important; }
        [data-broadway-tiles-path] > :not([data-broadway-tiles-path]):not([data-broadway-tiles-grid]):not([data-broadway-tiles-screen]) \
        { visibility: hidden !important; }
        [data-broadway-tiles-grid] { position: fixed !important; top: \(px(room.top)) !important; right: \(px(room.right)) !important; \
        bottom: \(px(room.bottom)) !important; left: \(px(room.left)) !important; width: auto !important; height: auto !important; \
        min-width: 0 !important; min-height: 0 !important; max-width: none !important; max-height: none !important; \
        margin: 0 !important; padding: 0 !important; border: 0 !important; border-radius: 0 !important; z-index: 2147483647 !important; \
        visibility: visible !important; background: transparent !important; overflow: visible !important; clip-path: none !important; \
        transform-origin: 0 0 !important; }
        [data-broadway-tiles-chrome], [data-broadway-tiles-grid] [data-participant-id] button, [data-broadway-tiles-grid] [role=toolbar], \
        [data-broadway-tiles-grid] [role=alert], [data-broadway-tiles-grid] [role=dialog] { visibility: hidden !important; }
        html[data-broadway-tiles=screen] body, html[data-broadway-tiles=screen] body *:not([data-broadway-tiles-screen]) \
        { visibility: hidden !important; }
        html[data-broadway-tiles=screen] [data-broadway-tiles-path] { opacity: 1 !important; clip-path: none !important; \
        mask: none !important; container-type: normal !important; content-visibility: visible !important; }
        html[data-broadway-tiles=screen] [data-broadway-tiles-screen] { position: fixed !important; transform: none !important; \
        filter: none !important; clip-path: none !important; mask: none !important; opacity: 1 !important; \
        min-width: 0 !important; min-height: 0 !important; max-width: none !important; max-height: none !important; \
        margin: 0 !important; padding: 0 !important; border: 0 !important; border-radius: \(px(corner)) !important; \
        box-shadow: none !important; background: #000 !important; z-index: 2147483647 !important; visibility: visible !important; }
        html[data-broadway-tiles=screen] video[data-broadway-tiles-screen] { object-fit: contain !important; }
        """
    }

    private static func px(_ value: Double) -> String { String(format: "%.2fpx", value) }
    private static func px(_ value: CGFloat) -> String { px(Double(value)) }

    private static func list(_ selectors: [String]) -> String {
        "[" + selectors.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    private static let marks = "['data-broadway-tiles-grid', 'data-broadway-tiles-path', 'data-broadway-tiles-chrome', 'data-broadway-tiles-screen']"

    static func enter(room: NSEdgeInsets, corner: CGFloat = 0) -> String {
        """
        (function () {
          var root = document.documentElement;
          var anchors = \(list(CallButtons.mic + CallButtons.camera + CallButtons.leave));
          function sized(el) { var r = el.getBoundingClientRect(); return r.width * r.height > 0; }
          function big(c) { var r = c.getBoundingClientRect(); return r.width >= 80 && r.height >= 60; }
          function outer(list) { return list.filter(function (el) { return !list.some(function (o) { return o !== el && o.contains(el); }); }); }
          function find(scope) {
            var found = outer([].slice.call(scope.querySelectorAll('[data-participant-id]')));
            if (!found.length) found = outer([].slice.call(scope.querySelectorAll('video')).filter(sized));
            if (!found.length) found = outer([].slice.call(scope.querySelectorAll('canvas')).filter(big));
            return found;
          }
          var tiles = find(document);
          var found = [];
          anchors.forEach(function (a) { [].forEach.call(document.querySelectorAll(a), function (el) { found.push(el); }); });
          function chromeIn(el) { return found.some(function (a) { return el.contains(a); }); }
          function clear() {
            \(marks).forEach(function (name) {
              [].forEach.call(document.querySelectorAll('[' + name + ']'), function (el) { el.removeAttribute(name); });
            });
            window.__broadwayCallScreen = null;
          }
          function drop(id) { var el = document.getElementById(id); if (el) el.remove(); }
          \(CallScreen.finding)
          function dress(mode) {
            var style = document.getElementById('broadway-call-tiles');
            if (!style) {
              style = document.createElement('style');
              style.id = 'broadway-call-tiles';
              (document.head || root).appendChild(style);
            }
            var text = \(jsString(style(room, corner: corner)));
            if (style.textContent !== text) style.textContent = text;
            if (root.getAttribute('data-broadway-tiles') !== mode) root.setAttribute('data-broadway-tiles', mode);
            window.__broadwayCallRoom = \(roomObject(room));
          }
          function write(text) {
            var fit = document.getElementById('broadway-call-fit');
            if (!fit) {
              fit = document.createElement('style');
              fit.id = 'broadway-call-fit';
              (document.head || root).appendChild(fit);
            }
            if (fit.textContent !== text) fit.textContent = text;
          }
          var lone = shared();
          var grid = lone ? null : tiles[0] || null;
          while (grid && !tiles.every(function (t) { return grid.contains(t); })) grid = grid.parentElement;
          if (grid && tiles.length === 1 && grid.parentElement && !chromeIn(grid.parentElement)) grid = grid.parentElement;
          if (!lone && (!grid || grid === document.body || grid === root)) {
            clear();
            root.removeAttribute('data-broadway-tiles');
            drop('broadway-call-tiles');
            drop('broadway-call-fit');
            return 'none';
          }
          if (lone) {
            if (!lone.hasAttribute('data-broadway-tiles-screen')) {
              var shape = lone.offsetHeight > 0 ? lone.offsetWidth / lone.offsetHeight : 0;
              clear();
              drop('broadway-call-fit');
              lone.setAttribute('data-broadway-tiles-screen', '');
              for (var up = lone.parentElement; up; up = up.parentElement) up.setAttribute('data-broadway-tiles-path', '');
              window.__broadwayCallScreen = { el: lone, stream: lone.srcObject || null, src: lone.currentSrc || '', shape: shape };
              setTimeout(function () { window.dispatchEvent(new Event('resize')); }, 0);
            }
            dress('screen');
          } else {
            if (!grid.hasAttribute('data-broadway-tiles-grid')) {
              clear();
              drop('broadway-call-fit');
              grid.setAttribute('data-broadway-tiles-grid', '');
              for (var p = grid.parentElement; p; p = p.parentElement) p.setAttribute('data-broadway-tiles-path', '');
              setTimeout(function () { window.dispatchEvent(new Event('resize')); }, 0);
            }
            found.forEach(function (a) {
              if (!grid.contains(a)) return;
              var top = a;
              while (top.parentElement && top.parentElement !== grid && !tiles.some(function (t) { return top.parentElement.contains(t); })) top = top.parentElement;
              if (!tiles.some(function (t) { return top.contains(t); })) top.setAttribute('data-broadway-tiles-chrome', '');
            });
            dress('');
          }
          window.__broadwayCallFitNow = function () {
            var room = window.__broadwayCallRoom;
            if (!room) return;
            var X = room.left, Y = room.top, W = innerWidth - room.left - room.right, H = innerHeight - room.top - room.bottom;
            if (W <= 0 || H <= 0) return;
            var one = document.querySelector('[data-broadway-tiles-screen]');
            if (one) {
              var kept = window.__broadwayCallScreen || {};
              var iw = one.videoWidth || 0, ih = one.videoHeight || 0;
              if (one.tagName === 'CANVAS') {
                if (getComputedStyle(one).objectFit === 'fill' && kept.shape > 0) { iw = kept.shape; ih = 1; } else { iw = one.width; ih = one.height; }
              }
              var k = iw > 0 && ih > 0 ? Math.min(W / iw, H / ih) : 0;
              var w = k ? iw * k : W, h = k ? ih * k : H;
              write('html[data-broadway-tiles=screen] [data-broadway-tiles-screen] { left: ' + (X + (W - w) / 2).toFixed(2) + 'px !important; top: '
                + (Y + (H - h) / 2).toFixed(2) + 'px !important; right: auto !important; bottom: auto !important; width: ' + w.toFixed(2)
                + 'px !important; height: ' + h.toFixed(2) + 'px !important; }');
              return;
            }
            var grid = document.querySelector('[data-broadway-tiles-grid]');
            if (!grid) return;
            var shown = getComputedStyle(grid).transform;
            var m = shown && shown !== 'none' ? new DOMMatrixReadOnly(shown) : new DOMMatrixReadOnly();
            var s = m.a || 1, tx = m.e, ty = m.f;
            var g = grid.getBoundingClientRect();
            var gx = g.left - tx, gy = g.top - ty;
            function local(r) {
              return { l: gx + (r.left - gx - tx) / s, t: gy + (r.top - gy - ty) / s, r: gx + (r.right - gx - tx) / s, b: gy + (r.bottom - gy - ty) / s };
            }
            function seen(el) {
              if (!el.getClientRects().length || el.hasAttribute('data-broadway-tiles-chrome')) return null;
              var css = getComputedStyle(el);
              if (css.visibility === 'hidden' || css.display === 'none') return null;
              var r = local(el.getBoundingClientRect());
              if (r.r - r.l < 1 || r.b - r.t < 1) return null;
              return r;
            }
            var people = find(grid);
            var boxes = people.map(seen).filter(Boolean);
            if (!boxes.length) return;
            var areas = boxes.map(function (b) { return (b.r - b.l) * (b.b - b.t); });
            var least = Math.min.apply(null, areas), most = Math.max.apply(null, areas);
            people.forEach(function (tile) {
              var parent = tile.parentElement;
              if (!parent || parent === grid.parentElement) return;
              [].forEach.call(parent.children, function (el) {
                if (people.indexOf(el) >= 0 || people.some(function (t) { return el.contains(t) || t.contains(el); })) return;
                var r = seen(el);
                if (!r) return;
                var area = (r.r - r.l) * (r.b - r.t);
                if (area >= least * 0.5 && area <= most * 1.5) boxes.push(r);
              });
            });
            if (people.length > 1) people.forEach(function (tile) {
              var top = tile;
              while (top.parentElement && top.parentElement !== grid
                && !people.some(function (o) { return o !== tile && top.parentElement.contains(o); })) top = top.parentElement;
              if (top === tile || !top.parentElement || top.parentElement === grid.parentElement) return;
              var own = seen(top);
              if (!own) return;
              var size = (own.r - own.l) * (own.b - own.t);
              [].forEach.call(top.parentElement.children, function (el) {
                if (el === top || people.some(function (t) { return el.contains(t) || t.contains(el); })) return;
                var r = seen(el);
                if (!r) return;
                var area = (r.r - r.l) * (r.b - r.t);
                if (area >= size * 0.5 && area <= size * 1.5) boxes.push(r);
              });
            });
            var u = boxes.reduce(function (a, b) {
              return { l: Math.min(a.l, b.l), t: Math.min(a.t, b.t), r: Math.max(a.r, b.r), b: Math.max(a.b, b.b) };
            });
            var uw = u.r - u.l, uh = u.b - u.t;
            var ns = Math.min(W / uw, H / uh, 4);
            var nx = X + (W - uw * ns) / 2 - gx - ns * (u.l - gx);
            var ny = Y + (H - uh * ns) / 2 - gy - ns * (u.t - gy);
            if (Math.abs(ns - s) < 0.001 && Math.abs(nx - tx) < 0.25 && Math.abs(ny - ty) < 0.25) return;
            write('[data-broadway-tiles-grid] { transform: translate(' + nx.toFixed(2) + 'px, ' + ny.toFixed(2) + 'px) scale(' + ns.toFixed(4) + ') !important; }');
          };
          window.__broadwayCallFitNow();
          if (!window.__broadwayCallFitting) {
            window.__broadwayCallFitting = true;
            var frame = 0;
            (function step() {
              if (!document.documentElement.hasAttribute('data-broadway-tiles')) { window.__broadwayCallFitting = false; return; }
              if (frame++ % 3 === 0 && window.__broadwayCallFitNow) window.__broadwayCallFitNow();
              requestAnimationFrame(step);
            })();
          }
          return lone ? 'screen' : tiles.length;
        })()
        """
    }

    static let leave = """
    (function () {
      \(marks).forEach(function (name) {
        [].forEach.call(document.querySelectorAll('[' + name + ']'), function (el) { el.removeAttribute(name); });
      });
      document.documentElement.removeAttribute('data-broadway-tiles');
      ['broadway-call-tiles', 'broadway-call-fit'].forEach(function (id) { var el = document.getElementById(id); if (el) el.remove(); });
      window.__broadwayCallFitNow = null;
      window.__broadwayCallRoom = null;
      window.__broadwayCallScreen = null;
      window.dispatchEvent(new Event('resize'));
      return true;
    })()
    """

    private static func roomObject(_ room: NSEdgeInsets) -> String {
        String(format: "{ top: %.2f, right: %.2f, bottom: %.2f, left: %.2f }", room.top, room.right, room.bottom, room.left)
    }

    private static func jsString(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [text])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}

@MainActor
@Observable
final class CallFloat {
    static let shared = CallFloat()
    static let size = NSSize(width: 340, height: 214)
    static let stage = NSEdgeInsets(top: 8, left: 8, bottom: 58, right: 8)
    static let radius: CGFloat = 14
    private static let spotKey = "call.spot"

    private(set) var status = CallButtons.Status()
    @ObservationIgnored private(set) weak var tab: Tab?
    @ObservationIgnored private(set) weak var owner: Browser?
    @ObservationIgnored private var panel: Panel?
    @ObservationIgnored private var ground: NSView?
    @ObservationIgnored private var ticking: Timer?
    @ObservationIgnored private var quiet = 0
    @ObservationIgnored private var zoom: CGFloat = 1
    @ObservationIgnored private var whole = false
    @ObservationIgnored private var flips = 0
    @ObservationIgnored private var closeAsked: (id: Tab.ID, at: Date)?
    @ObservationIgnored private var corners: CallCorners?
    @ObservationIgnored private(set) var away = CallAway()
    @ObservationIgnored private weak var awayTab: Tab?
    @ObservationIgnored private var awayWatch: Timer?
    @ObservationIgnored var tilesOnly = true { didSet { if tilesOnly != oldValue { tiles() } } }
    @ObservationIgnored let sizing = CallSizing()

    var showing: Bool { panel != nil }
    var frame: NSRect { panel?.frame ?? .zero }
    var window: NSWindow? { panel }

    func lift(_ tab: Tab, from browser: Browser) -> Bool {
        guard panel == nil else { return false }
        let web = tab.web
        let size = sizing.opening(on: browser.window?.screen)
        let panel = Panel(
            contentRect: NSRect(origin: spot(for: size, window: browser.window), size: size),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = KeepOnTop.panelLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.acceptsMouseMovedEvents = true
        panel.keys = { [weak self] event in self?.key(event) ?? false }

        let ground = NSView(frame: NSRect(origin: .zero, size: size))
        ground.autoresizingMask = [.width, .height]
        ground.wantsLayer = true
        ground.layer?.cornerRadius = Self.radius
        ground.layer?.cornerCurve = .continuous
        ground.layer?.masksToBounds = true
        ground.layer?.backgroundColor = NSColor.black.cgColor

        zoom = web.pageZoom
        whole = false
        flips = 0
        web.removeFromSuperview()
        web.alphaValue = 1
        web.frame = ground.bounds
        web.autoresizingMask = [.width, .height]
        web.pageZoom = wanted(size)
        ground.addSubview(web)

        let cover = Cover(frame: ground.bounds)
        cover.autoresizingMask = [.width, .height]
        cover.moved = { [weak self] in self?.keepSpot() }
        ground.addSubview(cover)

        let bar = CallBar(call: self)
        let room = bar.intrinsicContentSize
        bar.frame = NSRect(x: (size.width - room.width) / 2, y: 10, width: room.width, height: room.height)
        bar.autoresizingMask = [.minXMargin, .maxXMargin]
        ground.addSubview(bar)

        let corners = CallCorners(
            frame: ground.bounds,
            close: { [weak self] in self?.putAway() },
            back: { [weak self] in self?.goBack() }
        )
        corners.autoresizingMask = [.width, .height]
        corners.bar = bar
        ground.addSubview(corners)

        panel.contentView = ground
        sizing.attach(panel)
        sizing.resized = { [weak self] _ in self?.scale() }
        panel.makeFirstResponder(cover)
        panel.orderFrontRegardless()

        self.tab = tab
        owner = browser
        self.panel = panel
        self.ground = ground
        self.corners = corners
        quiet = 0
        tick()
        ticking = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        return true
    }

    func drop() {
        ticking?.invalidate()
        ticking = nil
        sizing.detach()
        keepSpot()
        tab?.built?.evaluateInSearch(CallTiles.leave)
        if let web = tab?.built, web.superview === ground {
            web.removeFromSuperview()
            web.autoresizingMask = []
            web.pageZoom = zoom
        }
        corners?.stop()
        corners = nil
        whole = false
        panel?.orderOut(nil)
        panel = nil
        ground = nil
        tab = nil
        owner = nil
        status = CallButtons.Status()
    }

    private func spot(for size: NSSize, window: NSWindow?) -> NSPoint {
        if Store.testing { return NSPoint(x: -20000, y: -20000) }
        let screen = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        if let kept = Store.settings.array(forKey: Self.spotKey) as? [Double], kept.count == 2 {
            let origin = NSPoint(x: kept[0], y: kept[1])
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(origin) }) { return origin }
        }
        return NSPoint(x: screen.maxX - size.width - 24, y: screen.minY + 24)
    }

    private func keepSpot() {
        guard let panel, !Store.testing else { return }
        Store.settings.set([Double(panel.frame.minX), Double(panel.frame.minY)], forKey: Self.spotKey)
    }

    private func tick() {
        guard let web = tab?.built, web.superview === ground else {
            end()
            return
        }
        quiet = StageView.onCall(web) ? 0 : quiet + 1
        if quiet >= 3 {
            end()
            return
        }
        tiles()
        web.evaluateInSearch(CallButtons.read) { [weak self, weak web] text in
            MainActor.assumeIsolated {
                guard let self, let web, web === self.tab?.built else { return }
                let found = CallButtons.status(text as? String, mic: web.microphoneCaptureState, camera: web.cameraCaptureState)
                if found != self.status { self.status = found }
            }
        }
    }

    static func room(zoom: CGFloat) -> NSEdgeInsets {
        let zoom = max(zoom, 0.01)
        return NSEdgeInsets(top: stage.top / zoom, left: stage.left / zoom, bottom: stage.bottom / zoom, right: stage.right / zoom)
    }

    static func corner(zoom: CGFloat) -> CGFloat {
        max(0, radius - stage.top) / max(zoom, 0.01)
    }

    private func wanted(_ size: NSSize) -> CGFloat {
        tilesOnly && !whole ? CallShape.zoom(tiles: size) : zoom * CallShape.zoom(width: size.width)
    }

    private func rezoom() -> Bool {
        guard let web = tab?.built, web.superview === ground, let panel else { return false }
        let wanted = wanted(panel.frame.size)
        guard abs(web.pageZoom - wanted) > 0.001 else { return false }
        web.pageZoom = wanted
        return true
    }

    private func scale() {
        if rezoom() { tiles() }
    }

    private func tiles() {
        guard let web = tab?.built, web.superview === ground else { return }
        _ = rezoom()
        let zoom = web.pageZoom
        let entering = tilesOnly
        let script = entering ? CallTiles.enter(room: Self.room(zoom: zoom), corner: Self.corner(zoom: zoom)) : CallTiles.leave
        web.evaluateInSearch(script) { [weak self, weak web] found in
            MainActor.assumeIsolated {
                guard let self, let web, web === self.tab?.built, entering == self.tilesOnly else { return }
                let whole = entering && found as? String == "none"
                guard whole != self.whole, whole || self.flips < 2 else { return }
                if whole { self.flips += 1 }
                self.whole = whole
                self.tiles()
            }
        }
        sizing.follow(web, tilesOnly: tilesOnly)
    }

    private func end() {
        if let owner { owner.land(covering: false) } else { drop() }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard let panel, event.window === panel, panel.attachedSheet == nil, NSApp.modalWindow == nil,
              !ShortcutStore.shared.recording else { return false }
        return key(event)
    }

    private func key(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let key = CallKey.read(code: event.keyCode, flags: event.modifierFlags, characters: event.charactersIgnoringModifiers)
        else { return false }
        switch key {
        case .mic: toggleMic()
        case .camera: toggleCamera()
        case .back:
            if event.isARepeat { return true }
            goBack()
        case .away:
            if event.isARepeat { return true }
            putAway()
        }
        return true
    }

    var cornersShown: Bool { corners?.chrome.shown ?? false }

    func hover(_ on: Bool) {
        corners?.hover(on)
    }

    func keepsAway(_ tab: Tab) -> Bool { away.keeps(tab.id) }

    func putAway() {
        guard let tab else { return }
        let owner = owner
        away.put(tab.id)
        awayTab = tab
        end()
        owner?.keepUnseen(tab)
        awayWatch?.invalidate()
        awayWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchAway() }
        }
    }

    private func watchAway() {
        if let tab = awayTab {
            away.heard(onCall: tab.built.map(StageView.onCall) ?? false)
        } else {
            away.gone()
        }
        guard away.tab == nil else { return }
        awayWatch?.invalidate()
        awayWatch = nil
        awayTab = nil
    }

    func toggleMic() {
        guard let web = tab?.built else { return }
        Self.toggleMic(web) { [weak self] in self?.tick() }
    }

    static func toggleMic(_ web: WKWebView, then: @escaping () -> Void = {}) {
        web.evaluateInSearch(CallButtons.press(CallButtons.mic)) { pressed in
            MainActor.assumeIsolated {
                if pressed as? Bool != true {
                    web.setMicrophoneCaptureState(web.microphoneCaptureState == .active ? .muted : .active) { then() }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { then() }
                }
            }
        }
    }

    func toggleCamera() {
        guard let web = tab?.built else { return }
        web.evaluateInSearch(CallButtons.press(CallButtons.camera)) { [weak self] pressed in
            MainActor.assumeIsolated {
                if pressed as? Bool != true {
                    web.setCameraCaptureState(web.cameraCaptureState == .active ? .muted : .active) { self?.tick() }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.tick() }
                }
            }
        }
    }

    func leave() {
        tab?.built?.evaluateInSearch(CallButtons.press(CallButtons.leave))
    }

    func goBack() {
        guard let owner, let tab else { return }
        owner.bring(tab)
    }

    func asksBeforeClosing(_ tab: Tab, in browser: Browser) -> Bool {
        guard browser.onCall(tab) else { return false }
        if let asked = closeAsked, asked.id == tab.id, Date().timeIntervalSince(asked.at) < 4 {
            closeAsked = nil
            return false
        }
        closeAsked = (tab.id, Date())
        browser.announce("On a call. Press ⌘W again to close this tab.")
        return true
    }

    final class Panel: KitLitPanel {
        var keys: ((NSEvent) -> Bool)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            keys?(event) == true || super.performKeyEquivalent(with: event)
        }
        override func keyDown(with event: NSEvent) {
            if keys?(event) != true { super.keyDown(with: event) }
        }
    }

    private final class Cover: NSView {
        var moved: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
            moved?()
        }
    }
}

extension Browser {
    func onCall(_ tab: Tab) -> Bool {
        tab.built.map(StageView.onCall) ?? false
    }

    func bring(_ tab: Tab) {
        if let space = parked.first(where: { $0.value.tabs.contains { $0.id == tab.id } })?.key {
            enter(space)
        }
        select(tab)
        if floating == tab.id { land() }
        guard !Store.testing else { return }
        Browsers.show(self)
        NSApp.activate()
    }

    func keepUnseen(_ tab: Tab) {
        guard let web = tab.built, web.superview == nil, let root = window?.contentView else { return }
        func stages(in view: NSView) -> [StageView] {
            (view as? StageView).map { [$0] } ?? view.subviews.flatMap(stages)
        }
        stages(in: root).max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }?.keepCall(web)
    }

    var callToMute: Tab? {
        if let floating = CallFloat.shared.tab, onCall(floating) { return floating }
        return Browsers.all.lazy.flatMap { $0.tabs + $0.parkedTabs }.first(where: onCall)
    }

    func muteCall() {
        guard let web = callToMute?.built else {
            announce("There's no call to mute")
            return
        }
        CallFloat.toggleMic(web)
    }
}

private final class CallBar: KitFlippedView {
    private let call: CallFloat
    private let glass = KitGlass.floating(radius: 20, ground: false)
    private let group = KitGlassGroup(spacing: 2)
    private lazy var mic = tool { [weak self] in self?.call.toggleMic() }
    private lazy var camera = tool { [weak self] in self?.call.toggleCamera() }
    private lazy var leave = tool(.destructive) { [weak self] in self?.call.leave() }

    init(call: CallFloat) {
        self.call = call
        super.init(frame: .zero)
        addSubview(glass)
        addSubview(group)
        for tool in [mic, camera, leave] { group.content.addSubview(tool) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var tools: [KitButton] {
        CallButtons.keys(call.status).map { key in
            switch key {
            case .mic: mic
            case .camera: camera
            case .leave: leave
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(tools.count)
        return NSSize(width: max(140, count * 32 + (count - 1) * 6 + 8), height: 40)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let status = call.status
        let shown = tools
        let count = CGFloat(shown.count)
        let width = count * 32 + (count - 1) * 6
        let box = kitSnap(NSRect(x: (bounds.width - width - 8) / 2, y: (bounds.height - 40) / 2, width: width + 8, height: 40))
        glass.frame = box
        glass.cornerRadius = 20
        glass.isHidden = shown.isEmpty
        group.frame = box.insetBy(dx: 4, dy: 4)
        group.isHidden = shown.isEmpty
        for tool in [mic, camera, leave] { tool.isHidden = !shown.contains(tool) }
        for (index, tool) in shown.enumerated() {
            tool.frame = NSRect(x: CGFloat(index) * 38, y: 0, width: 32, height: 32)
        }
        if let on = status.mic {
            face(mic, on ? "mic.fill" : "mic.slash.fill", on ? "Mute   ⌘D" : "Unmute   ⌘D", alert: !on)
        }
        if let on = status.camera {
            face(camera, on ? "video.fill" : "video.slash.fill", on ? "Stop Camera   ⌘E" : "Start Camera   ⌘E", alert: !on)
        }
        face(leave, "phone.down.fill", "Leave Call", tint: .white)
    }

    private func tool(_ kind: KitButton.Kind = .secondary, run: @escaping () -> Void) -> KitButton {
        let made = KitButton(.plain(press: 1), action: run)
        let glass = KitGlassFace(KitSymbol("mic.fill", style: KitSymbol.Style(size: 13, weight: .medium)))
        glass.effectIsInteractive = true
        made.content = glass
        kinds[ObjectIdentifier(made)] = kind
        return made
    }

    private var kinds: [ObjectIdentifier: KitButton.Kind] = [:]

    private func face(_ tool: KitButton, _ symbol: String, _ help: String, alert: Bool = false, tint: NSColor? = nil) {
        guard let glass = tool.content as? KitGlassFace, let image = glass.face as? KitSymbol else { return }
        let kind = kinds[ObjectIdentifier(tool)] ?? .secondary
        glass.plate = KitGlass.keyInk(kind, dark: kitDark)
        glass.tintColor = glass.plate == nil ? KitGlass.keyTint(kind, dark: kitDark) : nil
        image.name = symbol
        image.tint = tint ?? (alert ? Palette.NS.glassAlert : KitColor.ink)
        var style = image.style
        style.palette = alert ? [Palette.NS.glassAlert.kitResolved(dark: kitDark)] : []
        image.style = style
        tool.toolTip = help
        tool.setAccessibilityLabel(help.components(separatedBy: "   ").first ?? help)
        tool.setAccessibilityHelp(help)
    }
}

extension CallFloat {
    static func surface(mic: Bool?, camera: Bool?, leaves: Bool) -> NSView {
        let call = CallFloat()
        call.status = CallButtons.Status(mic: mic, camera: camera, leaves: leaves)
        let bar = CallBar(call: call)
        let size = bar.intrinsicContentSize
        return BenchFloating.sized(bar, NSSize(width: size.width + 8, height: size.height + 8))
    }
}

final class CallCorners: NSView {
    let chrome: FloatChrome
    let close: FloatCornerView
    let back: FloatCornerView
    weak var bar: NSView?
    private var reveal = FloatReveal()
    private var due: DispatchWorkItem?
    private var dueAt: TimeInterval = 0

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(frame: NSRect, close onClose: @escaping () -> Void, back onBack: @escaping () -> Void) {
        let chrome = FloatChrome()
        self.chrome = chrome
        close = FloatCornerView(chrome: chrome, anchor: KitArrival.topTrailing, symbol: "xmark", label: "Close", action: onClose)
        back = FloatCornerView(chrome: chrome, anchor: KitArrival.topLeading, symbol: "pip.exit", label: "Back to Tab", action: onBack)
        super.init(frame: frame)
        wantsLayer = true
        addSubview(close)
        addSubview(back)
        for corner in [close, back] { corner.key.addSubview(CallRing()) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        close.frame = FloatLayout.close(in: bounds)
        back.frame = FloatLayout.back(in: bounds)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        )
    }

    override func mouseEntered(with event: NSEvent) {
        reveal.enter(at: Self.now)
        apply()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        reveal.move(at: Self.now, overControl: target(at: point) != nil || overBar(point))
        apply()
    }

    override func mouseExited(with event: NSEvent) {
        reveal.exit(at: Self.now)
        apply()
    }

    func hover(_ on: Bool) {
        if on { reveal.enter(at: Self.now) } else { reveal.exit(at: Self.now) }
        apply()
    }

    func stop() {
        due?.cancel()
        due = nil
    }

    func target(at point: NSPoint) -> NSView? {
        guard chrome.shown else { return nil }
        let slop = FloatLayout.slop
        if close.frame.insetBy(dx: -slop, dy: -slop).contains(point) { return close }
        if back.frame.insetBy(dx: -slop, dy: -slop).contains(point) { return back }
        return nil
    }

    private func overBar(_ point: NSPoint) -> Bool {
        guard let bar, bar.superview === superview else { return false }
        return bar.frame.contains(convert(point, to: superview))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let inside = convert(point, from: superview)
        guard let host = target(at: inside) else { return nil }
        return host.hitTest(inside) ?? host
    }

    private func apply() {
        if reveal.shown != chrome.shown { chrome.shown = reveal.shown }
        guard let deadline = reveal.deadline else { return }
        if due != nil, deadline >= dueAt - 0.01 { return }
        due?.cancel()
        dueAt = deadline
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.due = nil
            self.reveal.tick(at: Self.now)
            self.apply()
        }
        due = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.02, deadline - Self.now), execute: work)
    }
}

final class CallRing: NSView {
    static let line = (width: CGFloat(1), white: CGFloat(0.4), alpha: CGFloat(0.5))
    private let shape = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(shape)
        shape.fillColor = nil
        shape.lineWidth = Self.line.width
        shape.strokeColor = NSColor(white: Self.line.white, alpha: Self.line.alpha).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var path: CGPath? { shape.path }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        autoresizingMask = [.width, .height]
        if let superview { frame = superview.bounds.insetBy(dx: -Self.line.width, dy: -Self.line.width) }
    }

    override func layout() {
        super.layout()
        shape.frame = bounds
        let inset = Self.line.width / 2
        shape.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
