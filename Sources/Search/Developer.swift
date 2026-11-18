import AppKit
import Combine
import Observation
import WebKit

enum LocalServer {
    static func isLocal(_ url: URL?) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased()), let host = url.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".localhost") || host.hasSuffix(".test")
    }

    static func port(_ url: URL?) -> Int? {
        isLocal(url) ? url?.port : nil
    }

    static func key(_ url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased()), let host = url.host()?.lowercased() else { return nil }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}

struct DevEntry: Identifiable, Equatable {
    enum Kind: String {
        case error, warning, log, info, debug, request
    }

    let id = UUID()
    let kind: Kind
    var message = ""
    var source = ""
    var line = 0
    var column = 0
    var stack = ""
    var sequence = 0
    var recorded = Date()
    var resourceType = ""
    var bytes: Int?
    var method = ""
    var url = ""
    var status = 0
    var milliseconds = 0
    var headers: [String: String] = [:]
    var body = ""

    var failed: Bool { kind == .request && (status == 0 || status >= 400) }

    static func parse(_ raw: [String: Any]) -> DevEntry? {
        func text(_ key: String, _ limit: Int = 4000) -> String { String((raw[key] as? String ?? "").prefix(limit)) }
        func number(_ key: String) -> Int { (raw[key] as? NSNumber)?.intValue ?? 0 }
        guard let kind = Kind(rawValue: raw["kind"] as? String ?? "") else { return nil }
        var entry = DevEntry(kind: kind)
        entry.message = text("message")
        entry.source = text("source", 600)
        entry.line = number("line")
        entry.column = number("column")
        entry.stack = text("stack", 8000)
        entry.method = text("method", 16).uppercased()
        entry.url = text("url", 2000)
        entry.status = number("status")
        entry.milliseconds = max(0, number("ms"))
        entry.resourceType = text("type", 60)
        entry.bytes = (raw["bytes"] as? NSNumber).map { max(0, $0.intValue) }
        entry.headers = (raw["headers"] as? [String: String] ?? [:]).reduce(into: [:]) { kept, pair in
            if kept.count < 40 { kept[String(pair.key.prefix(100))] = String(pair.value.prefix(2000)) }
        }
        entry.body = text("body", 20000)
        return entry
    }
}

enum DevCopy {
    private static let tokens: [(String, String)] = [
        (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer [removed]"),
        (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, "[token removed]"),
        (#"(?i)([?&](?:token|access_token|api_key|apikey|key|secret|password|auth|session)=)[^&\s"']+"#, "$1[removed]"),
    ]
    private static let secretHeaders: Set<String> = ["authorization", "cookie", "x-api-key", "x-auth-token", "proxy-authorization"]

    static func strip(_ text: String) -> String {
        tokens.reduce(text) { kept, rule in
            kept.replacingOccurrences(of: rule.0, with: rule.1, options: .regularExpression)
        }
    }

    static func agent(_ entry: DevEntry, page: String) -> String {
        var lines: [String] = []
        switch entry.kind {
        case .request:
            let status = entry.status == 0 ? "failed" : "\(entry.status)"
            lines.append("\(entry.method) \(entry.url) returned \(status) in \(entry.milliseconds) ms")
            lines.append("Page: \(page)")
            let headers = entry.headers.filter { !secretHeaders.contains($0.key.lowercased()) }
            if !headers.isEmpty {
                lines.append("Request headers:")
                lines += headers.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" }
            }
            if !entry.body.isEmpty { lines.append("Request body:\n\(entry.body)") }
        case .error, .warning, .log, .info, .debug:
            lines.append("\(entry.kind == .error ? "Error" : "Warning"): \(entry.message)")
            lines.append("Page: \(page)")
            if !entry.source.isEmpty { lines.append("At: \(entry.source):\(entry.line):\(entry.column)") }
        }
        return strip(lines.joined(separator: "\n"))
    }

    static func curl(_ entry: DevEntry) -> String {
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var parts = ["curl", quoted(entry.url)]
        if entry.method != "GET", !entry.method.isEmpty { parts += ["-X", entry.method] }
        for (name, value) in entry.headers.sorted(by: { $0.key < $1.key }) { parts += ["-H", quoted("\(name): \(value)")] }
        if !entry.body.isEmpty { parts += ["--data-raw", quoted(entry.body)] }
        return parts.joined(separator: " ")
    }
}

@MainActor
@Observable
final class DevLog {
    static let cap = 400
    private(set) var entries: [DevEntry] = []
    @ObservationIgnored let cursorID = UUID().uuidString.lowercased()
    @ObservationIgnored private(set) var sequence = 0

    var errors: [DevEntry] { entries.filter { $0.kind == .error || $0.kind == .warning } }
    var requests: [DevEntry] { entries.filter { $0.kind == .request } }
    var errorCount: Int { entries.filter { $0.kind == .error || $0.failed }.count }

    func add(_ entry: DevEntry) {
        var entry = entry
        sequence += 1
        entry.sequence = sequence
        entry.recorded = Date()
        entries.append(entry)
        if entries.count > Self.cap { entries.removeFirst(entries.count - Self.cap) }
    }

    func clear() {
        if !entries.isEmpty { entries = [] }
    }
}

final class DevRelay: NSObject, WKScriptMessageHandler {
    static let name = "broadwayDeveloper"
    private let log: DevLog

    @MainActor init(log: DevLog) {
        self.log = log
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard message.frameInfo.isMainFrame, let web = message.webView,
                  let browser = web.navigationDelegate as? Browser,
                  let tab = browser.popupTab(for: web), tab.devLog === log,
                  let page = tab.committed else { return }
            let origin = message.frameInfo.securityOrigin
            let scheme = origin.protocol.lowercased()
            let port = origin.port == 0 ? (scheme == "https" ? 443 : 80) : origin.port
            guard ["http", "https"].contains(scheme), scheme == page.scheme?.lowercased(),
                  origin.host.lowercased() == page.host()?.lowercased(),
                  port == (page.port ?? (scheme == "https" ? 443 : 80)),
                  let raw = message.body as? [String: Any], let entry = DevEntry.parse(raw) else { return }
            log.add(entry)
        }
    }
}

@MainActor
@Observable
final class Developer {
    static let shared = Developer()
    private static let key = "dev.servers"

    private(set) var servers: [String: Bool]
    var offer: String?
    @ObservationIgnored private var offered: Set<String> = []

    init() {
        servers = Store.settings.dictionary(forKey: Self.key) as? [String: Bool] ?? [:]
    }

    func isOn(_ url: URL?) -> Bool {
        guard let key = LocalServer.key(url) else { return false }
        return servers[key] == true
    }

    func set(_ key: String, _ on: Bool?) {
        servers[key] = on
        Store.settings.set(servers, forKey: Self.key)
    }

    func arrived(_ tab: Tab, offers: Bool) {
        guard offers, !tab.shy, LocalServer.isLocal(tab.pageAddress), let key = LocalServer.key(tab.pageAddress),
              servers[key] == nil, !offered.contains(key) else { return }
        offered.insert(key)
        offer = key
    }

    static let script = WKUserScript(source: #"""
    (function () {
      if (window.__broadwayDeveloper) return;
      Object.defineProperty(window, '__broadwayDeveloper', { value: true });
      var relay = window.webkit.messageHandlers.broadwayDeveloper;
      function post(entry) { try { relay.postMessage(entry); } catch (e) {} }
      function words(list) {
        return Array.from(list).map(function (x) {
          if (x instanceof Error) return x.stack || String(x);
          if (typeof x === 'object') { try { return JSON.stringify(x); } catch (e) { return String(x); } }
          return String(x);
        }).join(' ');
      }
      addEventListener('error', function (e) {
        var t = e.target;
        if (t && t !== window) {
          post({ kind: 'error', message: 'Failed to load ' + (t.src || t.href || t.tagName), source: t.src || t.href || '' });
          return;
        }
        post({ kind: 'error', message: e.message, source: e.filename, line: e.lineno, column: e.colno, stack: e.error && e.error.stack || '' });
      }, true);
      addEventListener('unhandledrejection', function (e) {
        var r = e.reason;
        post({ kind: 'error', message: 'Unhandled rejection: ' + (r && r.message || String(r)), stack: r && r.stack || '' });
      });
      ['error', 'warn', 'log', 'info', 'debug'].forEach(function (name) {
        var was = console[name];
        console[name] = function () {
          post({ kind: name === 'warn' ? 'warning' : name, message: words(arguments) });
          return was.apply(this, arguments);
        };
      });
      function absolute(u) { try { return new URL(u, location.href).href; } catch (e) { return String(u); } }
      function plain(headers) {
        var out = {};
        try { new Headers(headers || {}).forEach(function (v, k) { out[k] = v; }); } catch (e) {}
        return out;
      }
      var was = window.fetch;
      window.fetch = function (input, init) {
        var start = performance.now(), asked = input instanceof Request ? input : null;
        var entry = {
          kind: 'request', type: 'fetch',
          method: (init && init.method) || (asked && asked.method) || 'GET',
          url: absolute(asked ? asked.url : input),
          headers: plain((init && init.headers) || (asked && asked.headers)),
          body: init && typeof init.body === 'string' ? init.body : ''
        };
        return was.apply(this, arguments).then(function (r) {
          entry.status = r.status; entry.bytes = /^\d+$/.test(r.headers.get('content-length') || '') ? Number(r.headers.get('content-length')) : undefined; entry.ms = Math.round(performance.now() - start); post(entry);
          return r;
        }, function (e) {
          entry.status = 0; entry.ms = Math.round(performance.now() - start); entry.message = String(e); post(entry);
          throw e;
        });
      };
      var open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send, header = XMLHttpRequest.prototype.setRequestHeader;
      var seen = new WeakMap();
      XMLHttpRequest.prototype.open = function (method, url) {
        seen.set(this, { kind: 'request', type: 'xmlhttprequest', method: method, url: absolute(url), headers: {}, body: '' });
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
        var entry = seen.get(this); if (entry) entry.headers[name] = value;
        return header.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function (body) {
        var entry = seen.get(this), start = performance.now();
        if (entry) {
          if (typeof body === 'string') entry.body = body;
          this.addEventListener('loadend', function () {
            entry.status = this.status; var length = this.getResponseHeader('content-length'); entry.bytes = /^\d+$/.test(length || '') ? Number(length) : undefined; entry.ms = Math.round(performance.now() - start); post(entry);
          });
        }
        return send.apply(this, arguments);
      };
      if (window.PerformanceObserver) {
        new PerformanceObserver(function (list) {
          list.getEntries().forEach(function (r) {
            if (r.initiatorType === 'fetch' || r.initiatorType === 'xmlhttprequest') return;
            post({ kind: 'request', method: 'GET', url: r.name, status: r.responseStatus || 0, type: r.initiatorType || 'resource', bytes: r.transferSize || r.encodedBodySize || undefined, ms: Math.round(r.duration), headers: {} });
          });
        }).observe({ type: 'resource', buffered: true });
      }
    })();
    """#, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
}

extension Browser {
    func toggleDeveloperMode() {
        guard let tab = active, let key = LocalServer.key(tab.pageAddress) else { return }
        setDeveloperMode(!Developer.shared.isOn(tab.pageAddress), key: key)
    }

    func setDeveloperMode(_ on: Bool, key: String) {
        Developer.shared.set(key, on)
        Developer.shared.offer = nil
        LocalNetworkGuard.shared.refitAll()
        for tab in tabs + parkedTabs where tab.isWeb && LocalServer.key(tab.pageAddress) == key {
            tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
            if !on { tab.developerPanel = false }
            if tab.built != nil { tab.reload() }
        }
    }

    func toggleDeveloperPanel() {
        guard let tab = active, tab.isWeb else { return }
        guard Developer.shared.isOn(tab.pageAddress) else {
            announce("Turn on Developer Mode for this site first")
            return
        }
        tab.developerPanel.toggle()
    }
}

@MainActor
final class DeveloperBandView: KitFlippedView {
    static let height: CGFloat = 26

    private weak var browser: Browser?
    let tab: Tab
    private let log: DevLog
    private let address = NSTextField(labelWithString: "")
    private let phone = KitSymbol("iphone", style: .init(size: 11))
    private let warning = KitSymbol("exclamationmark.triangle.fill", style: .init(size: 9))
    private let count = KitLabel("0", font: .monospacedSystemFont(ofSize: 11, weight: .semibold))
    private lazy var deviceButton = KitButton(.plain(press: 1), label: "Device Mode") { [weak self] in self?.browser?.toggleDevice() }
    private lazy var errorsButton = KitButton(.plain(press: 1), label: "Errors and Network") { [weak self] in self?.tab.developerPanel.toggle() }
    private let errorsGroup = KitFlippedView()
    private let rule = KitBox(fill: .separatorColor)

    init(browser: Browser, tab: Tab, log: DevLog) {
        self.browser = browser
        self.tab = tab
        self.log = log
        super.init(frame: .zero)
        wantsLayer = true
        address.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        address.textColor = KitColor.ink
        address.lineBreakMode = .byTruncatingMiddle
        address.isSelectable = true
        address.cell?.usesSingleLineMode = true
        addSubview(address)
        deviceButton.content = phone
        deviceButton.kitAccess(help: "Device Mode")
        errorsGroup.addSubview(warning)
        errorsGroup.addSubview(count)
        errorsButton.content = errorsGroup
        errorsButton.kitAccess(help: "Errors and Network   ⌥⌘K")
        addSubview(deviceButton)
        addSubview(errorsButton)
        addSubview(rule)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.NS.ground.kitResolved(dark: kitDark).setFill()
        bounds.fill()
    }

    override func layout() {
        super.layout()
        let errors = log.errorCount
        let text = tab.pageAddress?.absoluteString ?? ""
        if address.stringValue != text { address.stringValue = text }
        phone.tint = tab.device == nil ? KitColor.muted : KitColor.ink
        count.text = "\(errors)"
        let tint = errors > 0 ? NSColor.systemRed : KitColor.muted
        warning.tint = tint
        count.color = tint
        errorsButton.setAccessibilityValue("\(errors)")
        let countSize = count.intrinsicContentSize
        let warningSize = warning.intrinsicContentSize
        let groupHeight = max(countSize.height, warningSize.height)
        warning.frame = kitSnap(NSRect(x: 0, y: (groupHeight - warningSize.height) / 2, width: warningSize.width, height: warningSize.height))
        count.frame = kitSnap(NSRect(x: warningSize.width + 4, y: (groupHeight - countSize.height) / 2, width: countSize.width, height: countSize.height))
        let groupWidth = warningSize.width + 4 + countSize.width
        let mid = (bounds.height - 1) / 2
        errorsButton.frame = kitSnap(NSRect(x: bounds.width - 12 - groupWidth, y: mid - groupHeight / 2, width: groupWidth, height: groupHeight))
        errorsGroup.frame = errorsButton.bounds
        let phoneSize = phone.intrinsicContentSize
        deviceButton.frame = kitSnap(NSRect(x: errorsButton.frame.minX - 10 - phoneSize.width, y: mid - phoneSize.height / 2,
                                            width: phoneSize.width, height: phoneSize.height))
        let addressHeight = ceil(address.intrinsicContentSize.height)
        address.frame = NSRect(x: 10, y: (mid - addressHeight / 2).rounded(.toNearestOrAwayFromZero),
                               width: max(0, deviceButton.frame.minX - 8 - 10 - 8), height: addressHeight)
        rule.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }
}

@MainActor
final class DeveloperPanelView: KitFlippedView {
    static let height: CGFloat = 228

    let tab: Tab
    private let log: DevLog
    private var showing: Int
    private lazy var errorsTab = PanelBar { [weak self] in self?.show(0) }
    private lazy var networkTab = PanelBar { [weak self] in self?.show(1) }
    private lazy var clear = PanelBar { [weak self] in self?.log.clear() }
    private let scroll = NSScrollView()
    private let list = KitFlippedView()
    private var rows: [UUID: DevRowView] = [:]
    private var order: [UUID] = []

    init(tab: Tab, log: DevLog, showing: Int = 0) {
        self.tab = tab
        self.log = log
        self.showing = showing
        super.init(frame: .zero)
        clear.set("Clear", on: false)
        for view in [errorsTab, networkTab, clear] as [NSView] { addSubview(view) }
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = list
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    private func show(_ which: Int) {
        showing = which
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.NS.ground.kitResolved(dark: kitDark).setFill()
        bounds.fill()
    }

    override func layout() {
        super.layout()
        let errors = log.errors
        let requests = log.requests
        errorsTab.set("Errors \(errors.count)", on: showing == 0)
        networkTab.set("Network \(requests.count)", on: showing == 1)
        var x: CGFloat = 12
        for bar in [errorsTab, networkTab] {
            let size = bar.intrinsicContentSize
            bar.frame = kitSnap(NSRect(x: x, y: (28 - size.height) / 2, width: size.width, height: size.height))
            x += size.width + 12
        }
        let clearSize = clear.intrinsicContentSize
        clear.frame = kitSnap(NSRect(x: bounds.width - 12 - clearSize.width, y: (28 - clearSize.height) / 2, width: clearSize.width, height: clearSize.height))
        scroll.frame = NSRect(x: 0, y: 28, width: bounds.width, height: 200)
        let page = tab.pageAddress?.absoluteString ?? ""
        let shown = Array((showing == 0 ? errors : requests).reversed())
        let ids = shown.map(\.id)
        if ids != order {
            for (id, row) in rows where !ids.contains(id) {
                row.removeFromSuperview()
                rows[id] = nil
            }
            for entry in shown where rows[entry.id] == nil {
                let row = DevRowView(entry: entry, page: page)
                rows[entry.id] = row
                list.addSubview(row)
            }
            order = ids
        }
        for (index, id) in order.enumerated() {
            rows[id]?.page = page
            rows[id]?.frame = NSRect(x: 0, y: CGFloat(index) * DevRowView.height, width: bounds.width, height: DevRowView.height)
        }
        list.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(200, CGFloat(order.count) * DevRowView.height))
    }
}

@MainActor
private final class PanelBar: KitButton {
    private let label = KitLabel("", font: .systemFont(ofSize: 12))

    init(run: @escaping () -> Void) {
        super.init(.plain(press: 1), action: run)
        label.setAccessibilityElement(false)
        content = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(_ title: String, on: Bool) {
        label.text = title
        label.font = .systemFont(ofSize: 12, weight: on ? .semibold : .regular)
        label.color = on ? KitColor.ink : KitColor.muted
        setAccessibilityLabel(title)
        setAccessibilityValue(on ? "selected" : nil)
        invalidateIntrinsicContentSize()
    }
}

@MainActor
final class DevRowView: KitHoverView {
    static let height: CGFloat = 22

    let entry: DevEntry
    var page: String
    private let title = KitLabel("", font: .monospacedSystemFont(ofSize: 11, weight: .regular))
    private let time = KitLabel("", font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: KitColor.muted)
    private lazy var agent = action("Copy for Agent") { [weak self] in
        guard let self else { return }
        Self.copy(DevCopy.agent(entry, page: page))
    }
    private lazy var curl = action("cURL") { [weak self] in
        guard let self else { return }
        Self.copy(DevCopy.curl(entry))
    }

    init(entry: DevEntry, page: String) {
        self.entry = entry
        self.page = page
        super.init(frame: .zero)
        title.text = entry.kind == .request ? "\(entry.status == 0 ? "ERR" : String(entry.status)) \(entry.method) \(entry.url)" : entry.message
        title.overflow = .middle
        title.color = entry.kind == .warning ? .systemOrange : entry.kind == .error || entry.failed ? .systemRed : KitColor.ink
        time.text = "\(entry.milliseconds) ms"
        time.isHidden = entry.kind != .request
        addSubview(title)
        addSubview(time)
        addSubview(agent)
        addSubview(curl)
        hoverChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func action(_ name: String, run: @escaping () -> Void) -> KitButton {
        let made = KitButton(.plain(press: 1), label: name, action: run)
        let label = KitLabel(name, font: .systemFont(ofSize: 11, weight: .medium))
        label.setAccessibilityElement(false)
        made.content = label
        return made
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func hoverChanged() {
        agent.isHidden = !hovering
        curl.isHidden = !hovering || entry.kind != .request
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var right = bounds.width - 12
        for view in [curl, agent, time] as [NSView] where !view.isHidden {
            let size = (view as? KitButton)?.intrinsicContentSize ?? view.intrinsicContentSize
            view.frame = kitSnap(NSRect(x: right - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
            right -= size.width + 8
        }
        let size = title.intrinsicContentSize
        let room = right - 8 - 12
        title.frame = kitSnap(NSRect(x: 12, y: (bounds.height - size.height) / 2, width: min(size.width, max(0, room)), height: size.height))
    }
}

@MainActor
final class OfferBarView: KitFlippedView, BarShrinks, KitOnGlass {
    struct Choice {
        var title: String
        var kind: KitButton.Kind
        var id: String?
        var run: () -> Void

        init(_ title: String, _ kind: KitButton.Kind = .secondary, id: String? = nil, run: @escaping () -> Void) {
            self.title = title
            self.kind = kind
            self.id = id
            self.run = run
        }
    }

    private let glass = KitGlass.floating(radius: 20)
    private let label: KitLabel
    let buttons: [KitButton]

    init(_ text: String, choices: [Choice]) {
        label = KitLabel(text, font: .systemFont(ofSize: 13))
        buttons = choices.map { choice in
            let made = Self.button(choice.title, kind: choice.kind, run: choice.run)
            if let id = choice.id { made.identifier = NSUserInterfaceItemIdentifier(id) }
            return made
        }
        super.init(frame: .zero)
        addSubview(glass)
        addSubview(label)
        for button in buttons { addSubview(button) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var text: String { label.text }

    private static func button(_ title: String, kind: KitButton.Kind, run: @escaping () -> Void) -> KitButton {
        let made = KitButton(.keycap(kind), label: title, action: run)
        let ink = kind == .primary ? NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white } : KitColor.ink
        let text = KitLabel(title, font: .systemFont(ofSize: 12, weight: kind == .primary ? .semibold : .regular), color: ink)
        text.setAccessibilityElement(false)
        made.content = text
        made.padding = 9
        made.height = SurfaceLook.key
        return made
    }

    private var buttonsWidth: CGFloat {
        buttons.map(\.intrinsicContentSize.width).reduce(0, +) + SurfaceLook.keyGap * CGFloat(max(0, buttons.count - 1))
    }

    private var ends: CGFloat { SurfaceLook.barLead + SurfaceLook.wordsToKeys + SurfaceLook.barTrail }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ends + label.intrinsicContentSize.width + buttonsWidth, height: SurfaceLook.bar)
    }

    var leastWidth: CGFloat { ends + 120 + buttonsWidth }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let size = label.intrinsicContentSize
        let room = max(0, bounds.width - ends - buttonsWidth)
        label.frame = kitSnap(NSRect(x: SurfaceLook.barLead, y: (bounds.height - size.height) / 2, width: min(size.width, room), height: size.height))
        var x = label.frame.maxX + SurfaceLook.wordsToKeys
        for button in buttons {
            let size = button.intrinsicContentSize
            button.frame = kitSnap(NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
            x += size.width + SurfaceLook.keyGap
        }
    }
}

@MainActor
enum DeveloperOfferView {
    static func make(key: String, turnOn: @escaping () -> Void, notNow: @escaping () -> Void) -> OfferBarView {
        OfferBarView("Turn on Developer Mode for \(key)?", choices: [.init("Not Now", run: notNow), .init("Turn On", .primary, run: turnOn)])
    }
}

@MainActor
final class DeveloperServersView: KitFormSection {
    private weak var browser: Browser?
    private let developer: Developer
    private var forget: [String: KitFormButton] = [:]
    private var toggles: [String: KitSwitch] = [:]

    init(browser: Browser?, developer: Developer = .shared) {
        self.browser = browser
        self.developer = developer
        super.init(frame: .zero)
    }

    override func spec() -> [KitFormLine] {
        let names = developer.servers.keys.sorted()
        guard !names.isEmpty else {
            return [line("none", "Servers", "None yet. Local pages offer Developer Mode as they load.", symbol: "server.rack")]
        }
        return names.map { name in
            let on = developer.servers[name] == true
            let button = forget[name] ?? KitForm.button("Forget") { [weak self] in self?.developer.set(name, nil) }
            forget[name] = button
            let toggle = toggles[name] ?? KitForm.toggle(name, isOn: on) { [weak self] in self?.browser?.setDeveloperMode($0, key: name) }
            toggles[name] = toggle
            toggle.set(on, animated: true)
            return line("server." + name, name, on ? "Developer Mode is on" : "Developer Mode is off", [button, toggle])
        }
    }
}

@MainActor
enum DeveloperSurface {
    static let address = "http://localhost:3000/dashboard/projects?tab=settings"

    static func log() -> DevLog {
        let log = DevLog()
        log.add(DevEntry(kind: .error, message: "Uncaught TypeError: nothing.here is not a function", source: "http://localhost:3000/app.js", line: 12, column: 4))
        log.add(DevEntry(kind: .warning, message: "Deprecated: componentWillMount has been renamed"))
        log.add(DevEntry(kind: .request, method: "GET", url: "http://localhost:3000/api/fine", status: 200, milliseconds: 12))
        log.add(DevEntry(kind: .request, method: "POST", url: "http://localhost:3000/api/broken", status: 500, milliseconds: 41))
        log.add(DevEntry(kind: .request, resourceType: "img", method: "GET", url: "http://localhost:3000/missing.png", status: 404, milliseconds: 3))
        log.add(DevEntry(kind: .request, method: "GET", url: "http://localhost:3000/api/slow", status: 0, milliseconds: 15000))
        return log
    }

    static func tab(device: Bool) -> Tab {
        let tab = Tab(bench: true)
        if let url = URL(string: address) { tab.hold(url) }
        return tab
    }

    static func servers(_ request: [String: Any]) {
        let wanted = request["servers"] as? [String: Bool] ?? [:]
        for key in Developer.shared.servers.keys where wanted[key] == nil { Developer.shared.set(key, nil) }
        for (key, on) in wanted { Developer.shared.set(key, on) }
    }

    static func make(_ request: [String: Any]) -> NSView? {
        let width = CGFloat(request["width"] as? Double ?? 720)
        switch request["part"] as? String ?? "band" {
        case "band":
            guard let browser = Browsers.all.first else { return nil }
            let log = request["clean"] as? Bool == true ? DevLog() : log()
            let view = DeveloperBandView(browser: browser, tab: tab(device: false), log: log)
            view.kitSize(width: width, height: DeveloperBandView.height)
            return view
        case "panel":
            let view = DeveloperPanelView(tab: tab(device: false), log: log(), showing: request["network"] as? Bool == true ? 1 : 0)
            view.kitSize(width: width, height: DeveloperPanelView.height)
            return view
        case "offer":
            return DeveloperOfferView.make(key: "localhost:3000", turnOn: {}, notNow: {})
        default:
            return nil
        }
    }
}
