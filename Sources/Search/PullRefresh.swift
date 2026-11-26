import AppKit
import WebKit

enum PullRefresh {
    static let key = "pages.pull"
    static let arm: CGFloat = 110
    static let least: TimeInterval = 0.2
    static let lingers = GestureDisc.lingers
    static let limit: TimeInterval = 8

    @MainActor static var on = true
    @MainActor static var continues = false

    static func on(in store: UserDefaults = Store.settings) -> Bool {
        store.object(forKey: key) as? Bool ?? true
    }

    static func progress(_ travel: CGFloat) -> CGFloat {
        max(0, travel) / arm
    }

    static let ask = "typeof window.__broadwayPull === 'function' ? window.__broadwayPull() : 'none'"
    static let typed = "typeof window.__broadwayTyped === 'function' && window.__broadwayTyped() === true"
    static let writers = 12

    static let watch = """
    (function () {
      if (window.__broadwayPull) return;
      var main = window === window.top;
      var typed = [], told = false;
      var kinds = { '': 1, text: 1, search: 1, email: 1, url: 1, tel: 1, number: 1, password: 1 };

      function first(e) {
        var path = e.composedPath ? e.composedPath() : [];
        return path.length ? path[0] : e.target;
      }
      function writes(el) {
        if (!el || el.nodeType !== 1) return false;
        if (el.tagName === 'TEXTAREA' || el.isContentEditable) return true;
        return el.tagName === 'INPUT' && kinds[(el.getAttribute('type') || '').toLowerCase()] === 1;
      }
      function forget(match) {
        typed = typed.filter(function (ref) {
          var el = ref.deref();
          return el && !match(el);
        });
      }
      function words(el) {
        if (typeof el.value === 'string') return el.value;
        return el.isContentEditable ? el.textContent || '' : '';
      }
      function held() {
        forget(function (el) { return !el.isConnected; });
        return typed.some(function (ref) {
          var el = ref.deref();
          return el && words(el).trim() !== '';
        });
      }

      addEventListener('input', function (e) {
        if (!e.isTrusted) return;
        var el = first(e);
        while (el && el.nodeType === 1 && el.isContentEditable && el.parentElement && el.parentElement.isContentEditable) el = el.parentElement;
        if (!writes(el)) return;
        if (typed.some(function (ref) { return ref.deref() === el; })) return;
        typed.push(new WeakRef(el));
        if (!main && !told) {
          told = true;
          window.webkit.messageHandlers.broadwayScroll.postMessage({ pull: 'typed', at: Date.now() });
        }
      }, { capture: true, passive: true });
      addEventListener('submit', function (e) {
        var form = e.target;
        forget(function (el) { return form && form.contains && form.contains(el); });
      }, true);
      addEventListener('keydown', function (e) {
        if (e.key !== 'Enter' || e.shiftKey || e.isComposing) return;
        var el = first(e);
        if (el && el.tagName === 'INPUT') forget(function (other) { return other === el; });
      }, true);

      function page() {
        if (document.contentType === 'application/pdf') return 'pdf';
        if (document.fullscreenElement || document.webkitFullscreenElement) return 'fullscreen';
        var vv = window.visualViewport;
        if (vv && vv.scale > 1.01) return 'pinched';
        if ((window.scrollY || 0) > 0.5) return 'scrolled';
        var html = getComputedStyle(document.documentElement).overscrollBehaviorY;
        var body = document.body ? getComputedStyle(document.body).overscrollBehaviorY : 'auto';
        if ((html && html !== 'auto') || (body && body !== 'auto')) return 'contained';
        if (held()) return 'typing';
        return '';
      }

      function under(e) {
        var path = e.composedPath ? e.composedPath() : [];
        for (var i = 0; i < path.length; i++) {
          var el = path[i];
          if (!el || el.nodeType !== 1 || el === document.documentElement) continue;
          var style = getComputedStyle(el), flow = style.overflowY;
          if (flow !== 'auto' && flow !== 'scroll' && flow !== 'overlay') continue;
          var room = el.scrollHeight - el.clientHeight;
          if (room <= 1) continue;
          var up = style.flexDirection === 'column-reverse' ? el.scrollTop + room : el.scrollTop;
          if (up > 0.5) return 'scroller';
          if (style.overscrollBehaviorY && style.overscrollBehaviorY !== 'auto') return 'contained';
        }
        return '';
      }

      var was = null, said = 0;
      function say(why, at) {
        var now = Date.now();
        if (why === was && now - said < 100) return;
        was = why; said = now;
        window.webkit.messageHandlers.broadwayScroll.postMessage({ pull: why || 'free', at: at });
      }

      addEventListener('wheel', function (e) {
        if (e.deltaY >= 0 || Math.abs(e.deltaX) >= Math.abs(e.deltaY)) return;
        var at = Date.now();
        var why = under(e) || page();
        if (why) return say(why, at);
        setTimeout(function () { say(e.defaultPrevented ? 'prevented' : '', at); }, 0);
      }, { passive: true, capture: true });

      window.__broadwayPull = page;
      window.__broadwayTyped = held;
      if (main) window.webkit.messageHandlers.broadwayScroll.postMessage({ pull: 'born', at: Date.now() });
    })();
    """
}

struct PullReading: Equatable {
    enum Change: Equatable { case none, pulled, dropped }
    enum Heard: Equatable { case nothing, dropped, ask }
    enum End: Equatable { case nothing, back, reload }

    struct Step: Equatable {
        var held = false
        var change = Change.none
        var tick: Bool?
    }

    var continues = false
    private(set) var live = false
    private(set) var spent = false
    private(set) var why = ""
    private(set) var top: String?
    private(set) var chain: String?
    private(set) var holding = false
    private(set) var travel: CGFloat = 0
    private(set) var peak: CGFloat = 0
    private(set) var armed = false
    private var across: CGFloat = 0
    private var along: CGFloat = 0
    private var away: CGFloat = 0
    private var decided = false
    private var first: TimeInterval?

    var ready: Bool { live && !spent && top == "" && chain == "free" }

    mutating func begin(refused: String? = nil) {
        self = PullReading(continues: continues)
        live = true
        if let refused { spend(refused) }
    }

    mutating func move(dx: CGFloat, dy: CGFloat, at time: TimeInterval) -> Step {
        guard live, !spent else { return Step() }
        if first == nil { first = time }
        if holding {
            let was = armed
            travel += dy
            guard travel > 0 else {
                spend("back")
                return Step(held: false, change: .dropped, tick: was ? false : nil)
            }
            peak = max(peak, travel)
            armed = travel >= PullRefresh.arm
            return Step(held: true, change: .pulled, tick: armed == was ? nil : armed)
        }
        if !decided {
            across += abs(dx)
            along += abs(dy)
            if across + along > 6 {
                decided = true
                if across > along * 1.3 {
                    spend("sideways")
                    return Step()
                }
            }
        }
        if dy < 0 { away -= dy }
        if !continues, away > 6 {
            spend("scrolling")
            return Step()
        }
        guard ready, decided, dy > 0 else { return Step() }
        holding = true
        travel = 0
        return Step(held: true, change: .pulled, tick: nil)
    }

    mutating func hear(top reason: String) -> Heard {
        guard live, !spent else { return .nothing }
        guard reason.isEmpty else {
            if continues, !holding {
                top = nil
                chain = nil
                why = reason
                return .nothing
            }
            return drop(reason)
        }
        top = ""
        return .nothing
    }

    mutating func hear(chain reason: String, frame: Bool) -> Heard {
        guard live, !spent else { return .nothing }
        guard reason == "free" else {
            if continues, !holding {
                chain = nil
                why = reason
                return .nothing
            }
            return drop(reason)
        }
        chain = "free"
        guard continues else { return .nothing }
        if frame {
            top = nil
            return .ask
        }
        top = ""
        return .nothing
    }

    mutating func end(at time: TimeInterval) -> End {
        defer { live = false }
        guard holding else { return .nothing }
        holding = false
        let long = first.map { time - $0 >= PullRefresh.least } ?? false
        if armed, long { return .reload }
        why = armed ? "flick" : "short"
        return .back
    }

    mutating func cancel() -> End {
        defer { live = false }
        guard holding else { return .nothing }
        holding = false
        why = "cancelled"
        return .back
    }

    private mutating func drop(_ reason: String) -> Heard {
        let was = holding
        spend(reason)
        return was ? .dropped : .nothing
    }

    private mutating func spend(_ reason: String) {
        spent = true
        why = reason
        holding = false
        travel = 0
        armed = false
    }
}

struct PullLog {
    var shown = false
    var peak: CGFloat = 0
    var armed = false
    var end = ""
    var why = ""
    var steps: [[Double]] = []
    var began: TimeInterval = 0
    var moved: TimeInterval = 0
    var top: TimeInterval = 0
    var chain: TimeInterval = 0
    var held: TimeInterval = 0
}

@MainActor
final class PullRefresher {
    var onRefresh: (() -> Void)?
    var allowed: (() -> Bool)?
    private(set) var reading = PullReading()
    private(set) var log = PullLog()
    private(set) var reloads = 0
    private(set) var disc: GestureDisc?
    private weak var web: PageView?
    private var watching: NSKeyValueObservation?
    private var ticket = 0
    private var began: Double = 0
    private var glides = false
    private var away = false
    private var reloading: Int?
    private var fired: TimeInterval = 0
    private var writers: [WKFrameInfo] = []

    init(_ web: PageView) {
        self.web = web
        away = web.isLoading
        watching = web.observe(\.isLoading, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated { self?.loads(web.isLoading) }
        }
    }

    var phase: String {
        if reloading != nil { return "reloading" }
        if reading.holding { return "pulling" }
        return disc == nil ? "idle" : "leaving"
    }

    func reads(_ event: NSEvent) -> Bool {
        guard let web else { return false }
        if event.momentumPhase != [] { return glides }
        switch event.phase {
        case .mayBegin, .began:
            glides = false
            begin(in: web)
        case .changed:
            if log.moved == 0 { log.moved = CACurrentMediaTime() }
            let step = reading.move(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, at: CACurrentMediaTime())
            follow(step)
            return step.held
        case .ended:
            finish(reading.end(at: CACurrentMediaTime()))
        case .cancelled:
            finish(reading.cancel())
        default:
            break
        }
        return false
    }

    func forget() {
        log = PullLog()
    }

    func heard(_ said: String, at: Double, frame: WKFrameInfo) {
        let main = frame.isMainFrame
        if said == "born" {
            if main {
                writers = []
                landed()
            }
            return
        }
        if said == "typed" {
            if !main { writers = Array((writers + [frame]).suffix(PullRefresh.writers)) }
            return
        }
        guard at >= began - 1 else { return }
        if log.chain == 0 { log.chain = CACurrentMediaTime() }
        act(reading.hear(chain: said, frame: !main))
    }

    private func begin(in web: PageView) {
        ticket += 1
        began = Date().timeIntervalSince1970 * 1000
        log = PullLog()
        log.began = CACurrentMediaTime()
        reading.continues = PullRefresh.continues
        reading.begin(refused: refusal(in: web))
        guard !reading.spent else {
            log.why = reading.why
            return
        }
        if !reading.continues { ask(web) }
    }

    private func refusal(in web: PageView) -> String? {
        if !PullRefresh.on { return "off" }
        if reloading != nil { return "reloading" }
        if away { return "leaving" }
        if web.fullscreenState != .notInFullscreen { return "fullscreen" }
        if web.magnification > 1.01 { return "pinched" }
        if allowed?() == false { return "floating" }
        return nil
    }

    private func ask(_ web: PageView) {
        let mine = ticket
        web.evaluateJavaScript(PullRefresh.ask, in: nil, in: Web.world) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.ticket == mine else { return }
                let said = (try? result.get()) as? String ?? "none"
                if self.log.top == 0 { self.log.top = CACurrentMediaTime() }
                if said.isEmpty {
                    self.ask(web, frames: self.writers, ticket: mine)
                } else {
                    self.act(self.reading.hear(top: said))
                }
            }
        }
    }

    private func ask(_ web: PageView, frames: [WKFrameInfo], ticket mine: Int) {
        guard let frame = frames.first else {
            act(reading.hear(top: ""))
            return
        }
        web.evaluateJavaScript(PullRefresh.typed, in: frame, in: Web.world) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.ticket == mine else { return }
                if (try? result.get()) as? Bool == true {
                    self.act(self.reading.hear(top: "typing"))
                } else {
                    self.ask(web, frames: Array(frames.dropFirst()), ticket: mine)
                }
            }
        }
    }

    private func act(_ heard: PullReading.Heard) {
        log.why = reading.why
        switch heard {
        case .nothing:
            break
        case .dropped:
            log.end = "dropped"
            disc?.back()
            disc = nil
        case .ask:
            if let web { ask(web) }
        }
    }

    private func follow(_ step: PullReading.Step) {
        if let tick = step.tick {
            NSHapticFeedbackManager.defaultPerformer.perform(tick ? .levelChange : .alignment, performanceTime: .now)
        }
        switch step.change {
        case .none:
            break
        case .pulled:
            guard let web else { return }
            let disc = disc ?? made(in: web)
            disc.follow(PullRefresh.progress(reading.travel), armed: reading.armed)
            if log.held == 0 { log.held = CACurrentMediaTime() }
            log.shown = true
            log.peak = reading.peak
            log.armed = log.armed || reading.armed
            if Store.testing { log.steps.append([CACurrentMediaTime(), reading.travel, disc.gap]) }
        case .dropped:
            log.why = reading.why
            log.end = "back"
            disc?.back()
            disc = nil
        }
    }

    private func made(in web: PageView) -> GestureDisc {
        web.subviews.compactMap { $0 as? GestureDisc }.forEach { $0.removeFromSuperview() }
        let made = GestureDisc(.top)
        web.addSubview(made)
        made.settle(in: web)
        disc = made
        return made
    }

    private func finish(_ end: PullReading.End) {
        log.why = reading.why
        switch end {
        case .nothing:
            break
        case .back:
            log.end = "back"
            disc?.back()
            disc = nil
        case .reload:
            log.end = "reload"
            fire()
        }
    }

    private func fire() {
        glides = true
        reloads += 1
        ticket += 1
        let mine = ticket
        reloading = mine
        fired = CACurrentMediaTime()
        disc?.commit()
        disc?.spin()
        onRefresh?()
        DispatchQueue.main.asyncAfter(deadline: .now() + PullRefresh.lingers) { [weak self] in
            guard let self, self.reloading == mine, self.web?.isLoading != true else { return }
            self.done()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + PullRefresh.limit) { [weak self] in
            guard let self, self.reloading == mine else { return }
            self.done()
        }
    }

    private func loads(_ loading: Bool) {
        away = loading
        if !loading { landed() }
    }

    private func landed() {
        away = false
        guard let mine = reloading else { return }
        let wait = max(0, fired + PullRefresh.lingers - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.reloading == mine else { return }
            self.done()
        }
    }

    private func done() {
        reloading = nil
        disc?.leave()
        disc = nil
    }
}
