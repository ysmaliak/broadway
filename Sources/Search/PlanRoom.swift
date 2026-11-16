import AppKit
import Combine

extension PlanLimit {
    init?(claude info: [String: Any]) {
        guard !info.isEmpty else { return nil }
        window = (info["rateLimitType"] as? String).map(Self.windowName) ?? "current"
        used = Self.number(info["utilization"])
        resets = Self.number(info["resetsAt"]).map(Date.init(timeIntervalSince1970:))
        out = info["status"] as? String == "rejected"
        if let windows = info["unifiedWindows"] as? [String: Any] {
            let fullest = windows.compactMap { name, value -> (String, [String: Any], Double)? in
                guard let window = value as? [String: Any], let share = Self.number(window["utilization"]) else { return nil }
                return (name, window, share)
            }.max { $0.2 < $1.2 }
            if let fullest, fullest.2 >= (used ?? 0) {
                self.window = Self.windowName(fullest.0)
                used = fullest.2
                resets = Self.number(fullest.1["resetsAt"]).map(Date.init(timeIntervalSince1970:)) ?? resets
            }
        }
    }

    init?(codex limits: [String: Any]) {
        let windows = ["primary", "secondary"].compactMap { limits[$0] as? [String: Any] }
        guard let fullest = windows.max(by: { Self.number($0["used_percent"]) ?? 0 < Self.number($1["used_percent"]) ?? 0 }) else { return nil }
        let share = (Self.number(fullest["used_percent"]) ?? 0) / 100
        let minutes = Self.number(fullest["window_minutes"]) ?? 0
        window = minutes >= 1440 ? "weekly" : minutes >= 60 ? "\(Int(minutes / 60))-hour" : "current"
        used = share
        resets = Self.number(fullest["resets_at"]).map(Date.init(timeIntervalSince1970:))
        out = share >= 1 || limits["rate_limit_reached_type"] is String
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func windowName(_ name: String) -> String {
        switch name {
        case "five_hour": return "5-hour"
        case "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_overage_included": return "weekly"
        case "overage": return "overage"
        default: return "current"
        }
    }

    var used100: Int? { used.map { Int(min($0, 1) * 100) } }
}

extension ChatStep {
    init(moving from: Plan, to next: Plan) {
        self.init(id: "moved-\(UUID().uuidString.prefix(8))", name: "Moved to \(next.name)", summary: "\(from.name) has run out for now", done: true)
    }
}

extension Plans {
    static let outFor: TimeInterval = 3600

    func note(_ limit: PlanLimit, on plan: Plan, at now: Date = Date()) {
        if limit.used != nil || limit.resets != nil || limits[plan] == nil { limits[plan] = limit }
        ranOut[plan] = limit.out ? now : nil
    }

    func noteOut(_ plan: Plan, at now: Date = Date()) {
        ranOut[plan] = now
    }

    func hasRoom(_ plan: Plan, at now: Date = Date()) -> Bool {
        guard let when = ranOut[plan] else { return true }
        if let resets = limits[plan]?.resets, resets > when { return resets <= now }
        return now.timeIntervalSince(when) >= Self.outFor
    }

    func withRoom(after plan: Plan, _ prefs: Preferences, at now: Date = Date()) -> ModelChoice? {
        guard plan != .thisMac, connected(plan.other), hasRoom(plan.other, at: now) else { return nil }
        return defaultChoice(plan.other)
    }

    func roomy(_ choice: ModelChoice, _ prefs: Preferences, at now: Date = Date()) -> ModelChoice {
        hasRoom(choice.plan, at: now) ? choice : withRoom(after: choice.plan, prefs, at: now) ?? choice
    }
}

enum PlanUsage {
    static func detail(_ limit: PlanLimit?, room: Bool, now: Date = Date()) -> String {
        guard let limit else { return room ? "Not measured yet" : "Ran out. Broadway will try again in about an hour." }
        var parts: [String] = []
        if let used = limit.used100 { parts.append("\(used)% of the \(limit.window) limit used") }
        if !room { parts = ["Ran out"] }
        if let resets = limit.resets, resets > now {
            parts.append("resets at \(resets.formatted(date: .omitted, time: .shortened))")
        }
        return parts.isEmpty ? "Not measured yet" : parts.joined(separator: " · ")
    }
}

final class PlanUsageRingView: NSView {
    static let side: CGFloat = 18

    var share: Double? { didSet { if share != oldValue { paint.needsDisplay = true } } }
    var out = false { didSet { if out != oldValue { paint.needsDisplay = true } } }

    private let paint = Paint()

    init(share: Double?, out: Bool) {
        self.share = share
        self.out = out
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        clipsToBounds = false
        paint.ring = self
        paint.frame = bounds.insetBy(dx: -2, dy: -2)
        addSubview(paint)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func layout() {
        super.layout()
        paint.frame = bounds.insetBy(dx: -2, dy: -2)
    }

    private final class Paint: NSView {
        weak var ring: PlanUsageRingView?

        override var isFlipped: Bool { true }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let ring else { return }
            let dark = kitDark
            let centre = NSPoint(x: bounds.midX, y: bounds.midY)
            let radius = PlanUsageRingView.side / 2
            let track = NSBezierPath()
            track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 3
            Palette.NS.wash.kitResolved(dark: dark).setStroke()
            track.stroke()
            guard let share = ring.share else { return }
            let part = min(max(share, 0), 1)
            guard part > 0 else { return }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: centre, radius: radius, startAngle: -90, endAngle: -90 + 360 * part, clockwise: false)
            arc.lineWidth = 3
            arc.lineCapStyle = .round
            (ring.out ? NSColor.systemOrange : KitColor.ink).kitResolved(dark: dark).setStroke()
            arc.stroke()
        }
    }
}

final class PlanUsageLineView: NSView, KitFits {
    let plans: Plans
    let plan: Plan
    private let line: KitFormLine
    private let ring = PlanUsageRingView(share: nil, out: false)
    private var watch: AnyCancellable?

    init(plans: Plans, plan: Plan) {
        self.plans = plans
        self.plan = plan
        line = KitFormLine("\(plan.name) usage", detail: " ", controls: [ring])
        line.firstLine = 0
        super.init(frame: .zero)
        kitPin(line)
        watch = kitTrack { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { line.intrinsicContentSize }

    func kitHeight(width: CGFloat) -> CGFloat { line.kitHeight(width: width) }

    func refresh() {
        let limit = plans.limits[plan]
        let room = plans.hasRoom(plan)
        let detail = PlanUsage.detail(limit, room: room)
        line.setText("\(plan.name) usage", detail: detail)
        ring.share = room ? limit?.used : 1
        ring.out = !room
        invalidateIntrinsicContentSize()
    }
}
