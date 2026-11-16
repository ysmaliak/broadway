import AppKit
import Combine

struct FootSpot: Equatable, Identifiable {
    enum Kind: Hashable {
        case space(UUID)
        case draft
    }

    let kind: Kind
    let icon: TabIcon
    let here: Bool
    let next: Bool

    var id: Kind { kind }
}

extension Browser {
    var draftComing: Bool { makingSpace || spaceNext == spaces.count }

    var stageVeiled: Bool { makingSpace && spaceNext == nil }

    func draftShare(progress: CGFloat) -> CGFloat {
        let share = min(1, max(0, progress))
        if makingSpace { return spaceNext == nil ? 1 : 1 - share }
        return spaceNext == spaces.count ? share : 0
    }

    var shownTab: Tab? { makingSpace ? nil : active }

    var draftIcon: TabIcon { spaceDraftIcon ?? freeIcon }

    var spaceAt: Int {
        makingSpace ? spaces.count : (spaces.firstIndex { $0.id == spaceID } ?? 0)
    }

    var spaceSeen: Int {
        guard let shown = spaceShown, shown != spaceAt, spaces.indices.contains(shown) else { return spaceAt }
        return shown
    }

    var spaceSliding: Bool {
        if let next = spaceNext, spaces.indices.contains(next) { return true }
        return spaceSeen != spaceAt
    }

    var seenLook: SpaceLook {
        let seen = spaceSeen
        guard seen != spaceAt else { return makingSpace ? draftLook : space.look ?? SpaceLook() }
        return spaces[seen].look ?? SpaceLook()
    }

    var footSpots: [FootSpot] {
        let seen = spaceSeen
        var spots = spaces.enumerated().map { index, space in
            FootSpot(kind: .space(space.id), icon: space.shownIcon,
                     here: index == seen && !(makingSpace && seen == spaceAt), next: spaceNext == index)
        }
        if makingSpace || spaceNext == spaces.count {
            spots.append(FootSpot(kind: .draft, icon: draftIcon, here: makingSpace && seen == spaceAt, next: spaceNext == spaces.count))
        }
        return spots
    }

    func row(at index: Int) -> (tabs: [Tab], active: Tab?)? {
        guard spaces.indices.contains(index) else { return nil }
        let id = spaces[index].id
        if id == spaceID { return (tabs, active) }
        guard let row = parked[id] else { return nil }
        return (row.tabs, row.active.flatMap { active in row.tabs.first { $0.id == active } })
    }
}

final class SpaceDraftStageView: NSView {
    let browser: Browser
    var corner: CGFloat { didSet { if corner != oldValue { needsLayout = true } } }

    private let ride: RideView
    private let face = StageBody()
    private var shown: KitBox?

    init(browser: Browser, corner: CGFloat) {
        self.browser = browser
        self.corner = corner
        ride = RideView(content: face, motion: browser.spaceMotion)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(ride)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !ride.isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {}

    private var fade: RideFade? {
        if browser.makingSpace { return browser.spaceNext == nil ? RideFade.none : .out }
        return browser.spaceNext == browser.spaces.count ? .in : nil
    }

    override func layout() {
        super.layout()
        browser.spaceNeighbour.watch()
        ride.frame = bounds
        guard browser.draftComing, let fade else {
            ride.isHidden = true
            shown?.removeFromSuperview()
            shown = nil
            return
        }
        ride.isHidden = false
        let ground = shown ?? KitBox(fill: KitColor.ground)
        if shown == nil {
            face.addSubview(ground)
            shown = ground
        }
        ground.corners = .radius(corner)
        ride.set(RideLook(here: browser.spaceAt, span: 0, clip: .none, band: false, fade: fade))
        ride.layoutSubtreeIfNeeded()
        ground.frame = face.bounds
    }
}
