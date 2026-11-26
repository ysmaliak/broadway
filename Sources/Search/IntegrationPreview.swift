import AppKit

struct IntegrationLink: Hashable {
    let service: IntegrationService
    let url: URL
    let owner: String
    let repository: String
    let number: String

    init?(_ address: String) {
        guard let url = URL(string: address), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host()?.lowercased() else { return nil }
        let parts = url.path().split(separator: "/").map(String.init)
        if host == "github.com" || host == "www.github.com" {
            guard parts.count >= 4, ["pull", "issues"].contains(parts[2]),
                  parts[0].range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"#, options: .regularExpression) != nil,
                  parts[1].range(of: #"^[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil,
                  parts[3].range(of: #"^[1-9][0-9]{0,8}$"#, options: .regularExpression) != nil else { return nil }
            service = .gitHub
            owner = parts[0].lowercased()
            repository = parts[1].lowercased()
            number = parts[3]
            self.url = URL(string: "https://github.com/\(owner)/\(repository)/\(parts[2])/\(number)")!
        } else if host == "linear.app" {
            guard parts.count >= 3, parts[1] == "issue",
                  parts[0].range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*$"#, options: .regularExpression) != nil,
                  parts[2].range(of: #"^[A-Za-z][A-Za-z0-9]{0,9}-[1-9][0-9]{0,8}$"#, options: .regularExpression) != nil else { return nil }
            service = .linear
            owner = parts[0].lowercased()
            repository = ""
            number = parts[2].uppercased()
            self.url = URL(string: "https://linear.app/\(owner)/issue/\(number)")!
        } else { return nil }
    }

    var identity: String { "\(service.rawValue):\(owner)/\(repository)#\(number)" }
    var reference: String { service == .gitHub ? "\(owner)/\(repository) #\(number)" : number }

    var body: Data {
        GraphQL.body("""
        query($id: String!) { issue(id: $id) { identifier title url updatedAt state { name } creator { name } } }
        """, variables: ["id": number])
    }
}

struct IntegrationPreview: Equatable {
    let title: String
    let reference: String
    let state: String?
    let checks: LiveChecks?
    let review: String?
    let author: String?
    let updated: Date?

    static func parse(_ data: Data, for link: IntegrationLink) -> Self? {
        guard link.service == .linear, let node = GraphQL.data(data)?["issue"] as? [String: Any],
              let title = node["title"] as? String, !title.isEmpty,
              let address = node["url"] as? String, let returned = IntegrationLink(address),
              returned.identity == link.identity else { return nil }
        return Self(title: title, reference: link.reference, state: (node["state"] as? [String: Any])?["name"] as? String,
                    checks: nil, review: nil, author: (node["creator"] as? [String: Any])?["name"] as? String,
                    updated: (node["updatedAt"] as? String).flatMap(GitHubAPI.date))
    }

    static func page(_ html: String, for link: IntegrationLink) -> Self? {
        func first(_ pattern: String, in text: String = "") -> String? {
            let text = text.isEmpty ? html : text
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        func words(_ text: String) -> String {
            var text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            for (from, to) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
                text = text.replacingOccurrences(of: from, with: to)
            }
            return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard link.service == .gitHub,
              let title = first(#"<(?:span|bdi)[^>]*class=["'][^"']*(?:js-issue-title|markdown-title)[^"']*["'][^>]*>(.*?)</(?:span|bdi)>"#)
                ?? first(#"<[^>]+data-testid=["']issue-title["'][^>]*>(.*?)</[^>]+>"#),
              !words(title).isEmpty else { return nil }
        let state = first(#"<(?:span|div)[^>]*class=["'][^"']*\bState(?:--[^\s"']+)?[^"']*["'][^>]*>(.*?)</(?:span|div)>"#).map(words)
        let allowed = ["Open", "Draft", "Merged", "Closed"]
        let shown = state.flatMap { value in allowed.first { value.caseInsensitiveCompare($0) == .orderedSame } }
        let reviewText = first(#"<(?:div|span)[^>]*class=["'][^"']*(?:review-status|merge-status)[^"']*["'][^>]*>(.*?)</(?:div|span)>"#).map(words)
        let review = reviewText.flatMap { value in ["Changes requested", "Review required", "Approved"].first { value.localizedCaseInsensitiveContains($0) } }
        let rollup = first(#"data-(?:status-check-rollup|checks-state)=["'](SUCCESS|FAILURE|ERROR|PENDING|EXPECTED)["']"#)
        let author = first(#"<a[^>]*class=["'][^"']*\bauthor\b[^"']*["'][^>]*>(.*?)</a>"#).map(words)
        let updated = (first(#"<relative-time(?=[^>]*data-testid=["']issue-updated-at["'])[^>]*datetime=["']([^"']+)["']"#)
                       ?? first(#"<meta(?=[^>]*itemprop=["']dateModified["'])[^>]*content=["']([^"']+)["']"#)).flatMap(GitHubAPI.date)
        return Self(title: words(title), reference: link.reference, state: shown, checks: GitHubAPI.checks(rollup?.uppercased()),
                    review: review, author: author, updated: updated)
    }
}

@MainActor
final class IntegrationPreviews {
    static let shared = IntegrationPreviews()
    static let lifetime: TimeInterval = 60
    private struct Key: Hashable { let space: UUID; let link: String }
    private struct Cached { let value: IntegrationPreview?; let until: Date }
    private var cache: [Key: Cached] = [:]
    private var pending: [Key: Task<IntegrationPreview?, Never>] = [:]
    private var generation = UUID()

    func clear() {
        generation = UUID()
        cache.removeAll()
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
    }

    func read(_ address: String, space: UUID, with given: Integrations? = nil, now: Date = Date()) async -> IntegrationPreview? {
        guard let link = IntegrationLink(address) else { return nil }
        let key = Key(space: space, link: link.identity)
        if let cached = cache[key], cached.until > now { return cached.value }
        if let task = pending[key] {
            let generation = generation
            let value = await task.value
            return generation == self.generation ? value : nil
        }
        let integrations = given ?? .shared
        let generation = generation
        let task = Task { await Self.fetch(link, space: space, integrations: integrations) }
        pending[key] = task
        let value = await task.value
        guard generation == self.generation else { return nil }
        pending[key] = nil
        cache = cache.filter { $0.value.until > now }
        if cache.count >= 128, let oldest = cache.min(by: { $0.value.until < $1.value.until })?.key { cache[oldest] = nil }
        cache[key] = Cached(value: value, until: now.addingTimeInterval(value == nil ? 15 : Self.lifetime))
        return value
    }

    private static func fetch(_ link: IntegrationLink, space: UUID, integrations: Integrations) async -> IntegrationPreview? {
        if link.service == .linear {
            guard case .answered(let data, let status, _)? = await IntegrationReader.sessionCall(
                link.body, space: space, workspace: link.owner, cookies: await IntegrationReader.cookies(space), transport: integrations.exchange
            ), (200..<300).contains(status) else { return nil }
            return IntegrationPreview.parse(data, for: link)
        }
        let cookies = LiveReader.cookies(await IntegrationReader.cookies(space), for: link.url)
        guard !cookies.isEmpty else { return nil }
        var url = link.url
        if let root = Integrations.fixture(.gitHub) { url = URL(string: root.absoluteString + "/page" + link.url.path())! }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: field) }
        guard let (data, status) = await integrations.transport(request), (200..<300).contains(status) else { return nil }
        return IntegrationPreview.page(String(decoding: data, as: UTF8.self), for: link)
    }
}

@MainActor
final class IntegrationPreviewDetailsView: KitFlippedView, KitHeightForWidth {
    var preview: IntegrationPreview { didSet { if preview != oldValue { fill() } } }

    private let reference = KitLabel("", font: .systemFont(ofSize: 12), color: KitColor.muted)
    private let title = PreviewLines(font: .systemFont(ofSize: 13, weight: .semibold))
    private let status = PreviewLines(font: .systemFont(ofSize: 12))
    private let author = KitLabel("", font: .systemFont(ofSize: 11), color: KitColor.muted)
    private let updated = KitLabel("", font: .systemFont(ofSize: 11), color: KitColor.muted)
    private var clock: Timer?

    static let relative: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.year, .month, .weekOfMonth, .day, .hour, .minute, .second]
        return formatter
    }()

    init(preview: IntegrationPreview) {
        self.preview = preview
        super.init(frame: .zero)
        for label in [reference, author, updated] {
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        for label in [title, status] {
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        fill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var checks: String? {
        switch preview.checks {
        case .passing: return "✓ Checks passing"
        case .failing: return "✗ Checks failing"
        case .pending: return "Checks pending"
        case nil: return nil
        }
    }

    private func fill() {
        reference.text = preview.reference
        title.text = preview.title
        status.text = [preview.state, checks, preview.review].compactMap { $0 }.joined(separator: " · ")
        author.text = preview.author ?? ""
        author.isHidden = preview.author == nil
        tick()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func tick() {
        updated.isHidden = preview.updated == nil
        if let date = preview.updated {
            updated.text = Self.relative.string(from: date, to: Date()) ?? ""
        }
        setAccessibilityLabel([preview.reference, preview.title, status.text, preview.author, updated.isHidden ? nil : updated.text]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clock?.invalidate()
        clock = nil
        guard window != nil, preview.updated != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let view = self else { return }
                let before = view.updated.text
                view.tick()
                if view.updated.text != before { view.needsLayout = true }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func lineHeight(_ label: KitLabel) -> CGFloat { ceil(label.measure(width: .greatestFiniteMagnitude).height) }


    private var footHeight: CGFloat { max(lineHeight(author), lineHeight(updated)) }

    func height(for width: CGFloat) -> CGFloat {
        lineHeight(reference) + 6 + title.height(for: width) + 6 + status.height(for: width) + 6 + footHeight
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(for: bounds.width > 0 ? bounds.width : 296))
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        var y: CGFloat = 0
        for (label, height) in [(reference as NSView, lineHeight(reference)), (title, title.height(for: width)), (status, status.height(for: width))] {
            label.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height + 6
        }
        var x: CGFloat = 0
        for label in [author, updated] where !label.isHidden {
            let size = label.intrinsicContentSize
            let w = min(size.width, max(0, width - x))
            label.frame = kitSnap(NSRect(x: x, y: y + (footHeight - size.height) / 2, width: w, height: size.height))
            x += w + 5
        }
    }
}

final class PreviewLines: KitFlippedView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    let font: NSFont

    init(font: NSFont) {
        self.font = font
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var allowsVibrancy: Bool { false }

    private func attributed(_ color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = .standard
        return NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    func height(for width: CGFloat) -> CGFloat {
        let line = ceil(NSAttributedString(string: " ", attributes: [.font: font]).boundingRect(with: NSSize(width: 1000, height: 100), options: [.usesLineFragmentOrigin]).height)
        let all = ceil(attributed(.black).boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin]).height)
        return min(all, line * 2)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        attributed(KitColor.ink.kitResolved(dark: kitDark)).draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

@MainActor
final class IntegrationHoverPreviewView: KitFlippedView {
    private(set) var address: String
    private(set) var space: UUID?
    private var details: IntegrationPreviewDetailsView?
    private let reference = KitLabel("", font: .systemFont(ofSize: 12), color: KitColor.muted)
    private let waiting = KitLabel("", font: .systemFont(ofSize: 13), color: KitColor.muted)
    private var task: Task<Void, Never>?
    private var preview: IntegrationPreview?
    private var finished = false

    init(address: String, space: UUID?) {
        self.address = address
        self.space = space
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(reference)
        addSubview(waiting)
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(address: String, space: UUID?) {
        guard address != self.address || space != self.space else { return }
        self.address = address
        self.space = space
        load()
    }

    override func removeFromSuperview() {
        task?.cancel()
        super.removeFromSuperview()
    }

    private func load() {
        task?.cancel()
        set(nil, finished: false, animated: false)
        guard let space else {
            set(nil, finished: true, animated: false)
            return
        }
        let address = address
        task = Task { @MainActor [weak self] in
            let found = await IntegrationPreviews.shared.read(address, space: space)
            guard !Task.isCancelled, let self, self.address == address else { return }
            set(found, finished: true, animated: true)
        }
    }

    private func set(_ preview: IntegrationPreview?, finished: Bool, animated: Bool) {
        let changed = preview != self.preview
        self.preview = preview
        self.finished = finished
        if let preview {
            if let details { details.preview = preview } else {
                let made = IntegrationPreviewDetailsView(preview: preview)
                addSubview(made)
                details = made
            }
        } else {
            details?.removeFromSuperview()
            details = nil
        }
        let link = IntegrationLink(address)
        reference.text = link?.reference ?? ""
        waiting.text = finished ? "Preview unavailable" : "Reading preview…"
        reference.isHidden = preview != nil || link == nil
        waiting.isHidden = preview != nil || link == nil
        if animated && changed { layer?.kitTransition(Motion.kitSettle) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inner = NSRect(x: 8, y: 8, width: max(0, bounds.width - 16), height: max(0, bounds.height - 16))
        if let details {
            details.frame = NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: min(inner.height, details.height(for: inner.width)))
        }
        let top = reference.intrinsicContentSize.height
        reference.frame = kitSnap(NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: top))
        waiting.frame = kitSnap(NSRect(x: inner.minX, y: inner.minY + top + 6, width: inner.width, height: waiting.intrinsicContentSize.height))
    }
}

@MainActor
enum IntegrationPreviewSurface {
    static let updated = Date(timeIntervalSince1970: 1_577_836_800)
    static let github = IntegrationPreview(title: "Keep the upload alive when the laptop sleeps between chunks", reference: "acme/rocket #412",
                                           state: "Open", checks: .failing, review: "Changes requested", author: "dana", updated: updated)
    static let linear = IntegrationPreview(title: "Search results lose their place", reference: "ENG-231", state: "In Progress",
                                           checks: nil, review: nil, author: "Sam Octo", updated: updated)

    static func make(_ request: [String: Any]) -> NSView {
        let preview = request["kind"] as? String == "linear" ? linear : github
        let width = CGFloat(request["width"] as? Double ?? 320)
        let box = KitFlippedView()
        let details = IntegrationPreviewDetailsView(preview: preview)
        box.addSubview(details)
        details.frame = NSRect(x: 12, y: 12, width: width - 24, height: details.height(for: width - 24))
        box.kitSize(width: width, height: 148)
        return box
    }

    static func hover(_ request: [String: Any]) -> NSView {
        let width = CGFloat(request["width"] as? Double ?? 252)
        let view = IntegrationHoverPreviewView(address: "https://github.com/acme/rocket/pull/412", space: nil)
        view.kitSize(width: width, height: 148)
        return view
    }
}
