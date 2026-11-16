import AppKit
import Combine
import WebKit

struct DeviceProfile: Identifiable, Hashable {
    enum Agent: Hashable {
        case iPhone, iPad, android, androidTablet

        var text: String {
            switch self {
            case .iPhone:
                return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
            case .iPad:
                return "Mozilla/5.0 (iPad; CPU OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
            case .android:
                return "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36"
            case .androidTablet:
                return "Mozilla/5.0 (Linux; Android 14; SM-X910) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
            }
        }
    }

    let name: String
    let width: CGFloat
    let height: CGFloat
    let agent: Agent
    var id: String { name }

    static let list: [DeviceProfile] = [
        .init(name: "iPhone SE", width: 375, height: 667, agent: .iPhone),
        .init(name: "iPhone 15", width: 393, height: 852, agent: .iPhone),
        .init(name: "iPhone 15 Pro Max", width: 430, height: 932, agent: .iPhone),
        .init(name: "Pixel 8", width: 412, height: 915, agent: .android),
        .init(name: "Galaxy S24", width: 360, height: 780, agent: .android),
        .init(name: "iPad Mini", width: 768, height: 1024, agent: .iPad),
        .init(name: "iPad Air", width: 820, height: 1180, agent: .iPad),
        .init(name: "iPad Pro", width: 1024, height: 1366, agent: .iPad),
        .init(name: "Galaxy Tab S9", width: 800, height: 1280, agent: .androidTablet),
    ]

    static let standard = list[1]
}

struct DeviceState: Equatable {
    static let smallest: CGFloat = 200

    var name: String
    var width: CGFloat
    var height: CGFloat
    var agent: DeviceProfile.Agent

    init(_ profile: DeviceProfile) {
        name = profile.name
        width = profile.width
        height = profile.height
        agent = profile.agent
    }

    mutating func rotate() {
        swap(&width, &height)
    }

    mutating func resize(width newWidth: CGFloat? = nil, height newHeight: CGFloat? = nil) {
        if let newWidth { width = max(Self.smallest, newWidth.rounded()) }
        if let newHeight { height = max(Self.smallest, newHeight.rounded()) }
        name = "Custom"
    }

    static func drag(from start: CGFloat, by travel: CGFloat, fine: Bool) -> CGFloat {
        start + travel * 2 / (fine ? 4 : 1)
    }
}

extension StageView {
    static func deviceFrame(_ size: NSSize, in bounds: NSRect) -> NSRect {
        let width = min(size.width, bounds.width), height = min(size.height, bounds.height)
        return NSRect(x: floor(bounds.midX - width / 2), y: floor(bounds.midY - height / 2), width: width, height: height)
    }
}

extension Tab {
    func useDevice(_ state: DeviceState?) {
        let agent = state?.agent.text
        let changed = built.map { $0.customUserAgent != (agent ?? "") } ?? false
        device = state
        guard let web = built else { return }
        (web as? PageView)?.deviceSize = state.map { NSSize(width: $0.width, height: $0.height) }
        if changed {
            web.customUserAgent = agent
            reload()
        }
    }
}

extension Browser {
    func toggleDevice() {
        guard let tab = active, tab.isWeb else { return }
        if tab.device != nil {
            tab.useDevice(nil)
            return
        }
        guard activeSplit == nil else {
            announce("Device Mode is for one page at a time")
            return
        }
        tab.useDevice(DeviceState(.standard))
    }
}

final class DeviceBarView: NSView {
    let tab: Tab

    private let picker = NSPopUpButton(frame: .zero, pullsDown: true)
    private let measure = KitLabel("", font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: KitColor.muted)
    private let rotate: KitDoor
    private let leave: KitDoor
    private let line = KitBox(fill: .separatorColor)
    private var watch: AnyCancellable?

    init(tab: Tab) {
        self.tab = tab
        rotate = KitDoor(icon: "rotate.right", help: "Rotate", size: 11, box: 22) { [weak tab] in
            guard let tab, var turned = tab.device else { return }
            turned.rotate()
            tab.useDevice(turned)
        }
        leave = KitDoor(icon: "xmark", help: "Leave Device Mode", size: 10, box: 22) { [weak tab] in tab?.useDevice(nil) }
        super.init(frame: .zero)
        wantsLayer = true
        picker.isBordered = false
        picker.font = .systemFont(ofSize: 12, weight: .medium)
        (picker.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        for view in [picker, measure, rotate, leave, line] as [NSView] { addSubview(view) }
        watch = kitObserve(initial: false, { [weak tab] in tab?.device }) { [weak self] _ in self?.refresh() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: tab.device == nil ? 0 : 28)
    }

    override func updateLayer() {
        layer?.backgroundColor = Palette.NS.ground.kitResolved(dark: kitDark).cgColor
    }

    private func refresh() {
        isHidden = tab.device == nil
        invalidateIntrinsicContentSize()
        guard let device = tab.device else { return }
        let items = [KitMenuItem.action(device.name) {}] + DeviceProfile.list.map { profile in
            KitMenuItem.action(profile.name) { [weak tab] in tab?.useDevice(DeviceState(profile)) }
        }
        let made = KitMenu.make(items)
        made.font = picker.font
        picker.menu = made
        picker.select(nil)
        picker.title = device.name
        measure.text = "\(Int(device.width)) × \(Int(device.height))"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        picker.sizeToFit()
        let menuSize = picker.fittingSize
        picker.frame = kitSnap(NSRect(x: 7, y: (height - menuSize.height) / 2, width: menuSize.width, height: menuSize.height))
        let measureSize = measure.intrinsicContentSize
        measure.frame = kitSnap(NSRect(x: picker.frame.maxX + 10, y: (height - measureSize.height) / 2, width: measureSize.width, height: measureSize.height))
        leave.frame = NSRect(x: bounds.width - 12 - 22, y: (height - 22) / 2, width: 22, height: 22)
        rotate.frame = NSRect(x: leave.frame.minX - 10 - 22, y: (height - 22) / 2, width: 22, height: 22)
        let scale = window?.backingScaleFactor ?? 2
        line.frame = NSRect(x: 0, y: height - 1 / scale, width: bounds.width, height: 1 / scale)
    }

    static func surface() -> NSView {
        let tab = BenchArt.tab("Device", address: "https://www.example.com")
        tab.device = DeviceState(.standard)
        let bar = DeviceBarView(tab: tab)
        bar.frame = NSRect(x: 0, y: 0, width: 560, height: 28)
        return BenchPadded(bar, pad: 0)
    }
}

final class DeviceHandlesView: NSView {
    let tab: Tab

    private let right = DeviceEdge(cursor: .resizeLeftRight)
    private let bottom = DeviceEdge(cursor: .resizeUpDown)
    private var watch: AnyCancellable?

    init(tab: Tab) {
        self.tab = tab
        super.init(frame: .zero)
        addSubview(right)
        addSubview(bottom)
        right.change = { [weak self] state, travel, fine in
            state.resize(width: DeviceState.drag(from: state.width, by: travel.width, fine: fine))
            self?.tab.useDevice(state)
        }
        bottom.change = { [weak self] state, travel, fine in
            state.resize(height: DeviceState.drag(from: state.height, by: travel.height, fine: fine))
            self?.tab.useDevice(state)
        }
        right.tab = tab
        bottom.tab = tab
        watch = kitObserve(initial: false, { [weak tab] in tab?.device }) { [weak self] _ in self?.needsLayout = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard tab.device != nil else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        guard let device = tab.device else {
            right.isHidden = true
            bottom.isHidden = true
            return
        }
        right.isHidden = false
        bottom.isHidden = false
        let spot = StageView.deviceFrame(NSSize(width: device.width, height: device.height), in: NSRect(origin: .zero, size: bounds.size))
        right.frame = NSRect(x: spot.maxX, y: spot.minY, width: 8, height: spot.height)
        bottom.frame = NSRect(x: spot.minX, y: spot.maxY, width: spot.width, height: 8)
    }
}

private final class DeviceEdge: KitHoverView {
    let cursor: NSCursor
    weak var tab: Tab?
    var change: ((inout DeviceState, CGSize, Bool) -> Void)?

    private var start: DeviceState?
    private var origin: NSPoint = .zero

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = KitColor.ink.kitResolved(dark: kitDark).withAlphaComponent(hovering ? 0.25 : 0.1).cgColor
    }

    override func hoverChanged() {
        layer?.kitTransition(.none)
        needsDisplay = true
        if hovering { cursor.push() } else { NSCursor.pop() }
    }

    override func mouseDown(with event: NSEvent) {
        start = tab?.device
        origin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard var state = start else { return }
        let point = event.locationInWindow
        let travel = CGSize(width: point.x - origin.x, height: origin.y - point.y)
        guard abs(travel.width) >= 1 || abs(travel.height) >= 1 else { return }
        change?(&state, travel, NSEvent.modifierFlags.contains(.shift))
    }

    override func mouseUp(with event: NSEvent) {
        start = nil
    }
}
