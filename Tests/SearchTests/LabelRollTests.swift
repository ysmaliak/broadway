import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class LabelRollTests {
    private var windows: [NSWindow] = []

    init() {
        addTeardownBlock { await self.tearDown() }
        Store.settings.set(true, forKey: "roll.testShown")
        Store.settings.set(false, forKey: "motion.testReduced")
        Store.settings.set(false, forKey: "motion.testLowPower")
    }

    private func tearDown() async {
        for key in ["roll.testShown", "motion.testReduced", "motion.testLowPower"] { Store.settings.removeObject(forKey: key) }
        for window in windows { window.contentView = nil }
        windows = []
    }

    private func tick(_ old: String, _ new: String, same: Bool = true, shown: Bool = true,
                      reduced: Bool = false, light: Bool = false) -> AddressMove {
        AddressMove.tick(old, new, same: same, shown: shown, reduced: reduced, light: light)
    }

    private func label(in window: Bool = true) -> KitLabel {
        let made = KitLabel("", font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: KitColor.muted)
        made.frame = NSRect(x: 10, y: 10, width: 120, height: 16)
        guard window else { return made }
        let shown = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: .borderless, backing: .buffered, defer: false)
        shown.isReleasedWhenClosed = false
        shown.contentView?.wantsLayer = true
        shown.contentView?.addSubview(made)
        windows.append(shown)
        return made
    }

    private func pieces(_ label: KitLabel) -> [NSView] { label.rolled?.pieces ?? [] }

    private func coming(_ label: KitLabel) -> [NSView] {
        pieces(label).filter { ($0.layer?.animation(forKey: "glide.opacity") as? CAKeyframeAnimation)?.values?.first as? Int == 0 }
    }

    private func leaving(_ label: KitLabel) -> [NSView] {
        pieces(label).filter { ($0.layer?.animation(forKey: "glide.opacity") as? CAKeyframeAnimation)?.values?.first as? Int == 1 }
    }

    private func rise(_ piece: NSView) -> CGFloat? {
        guard let move = piece.layer?.animation(forKey: "glide.position") as? CABasicAnimation,
              let from = (move.fromValue as? NSValue)?.pointValue, let to = (move.toValue as? NSValue)?.pointValue else { return nil }
        return from.y - to.y
    }

    @Test func aGrowingNumberBringsItsNewDigitsUpFromBelow() {
        #expect(tick("9m ago", "10m ago") == .roll(down: true))
        #expect(tick("10", "100") == .roll(down: true))
        #expect(tick("0:59", "1:00") == .roll(down: true))
    }

    @Test func aShrinkingNumberBringsItsNewDigitsDownFromAbove() {
        #expect(tick("10m left", "9m left") == .roll(down: false))
        #expect(tick("12m", "1m") == .roll(down: false))
        #expect(tick("In 3 min", "In 2 min") == .roll(down: false))
    }

    @Test func aChangeThatIsNotANumberComesUpFromBelow() {
        #expect(tick("1m", "Join") == .roll(down: true))
        #expect(tick("59m ago", "1h ago") == .roll(down: true))
        #expect(tick("In 1 min", "Now") == .roll(down: true))
    }

    @Test func onlyTheCharactersThatChangeMove() {
        typealias Part = AddressMove.Ticks.Part

        #expect(AddressMove.Ticks.parts("10m ago", "11m ago") == [Part(old: 0..<1, new: 0..<1, moves: false),
                                                                  Part(old: 1..<2, new: 1..<2, moves: true),
                                                                  Part(old: 2..<7, new: 2..<7, moves: false)])
        #expect(AddressMove.Ticks.parts("9m ago", "10m ago") == [Part(old: 0..<1, new: 0..<2, moves: true),
                                                                 Part(old: 1..<6, new: 2..<7, moves: false)])
        #expect(AddressMove.Ticks.parts("1:59", "2:00") == [Part(old: 0..<1, new: 0..<1, moves: true),
                                                            Part(old: 1..<2, new: 1..<2, moves: false),
                                                            Part(old: 2..<4, new: 2..<4, moves: true)])
    }

    @Test func underReduceMotionTheTextChangesAtOnce() {
        #expect(tick("5m left", "4m left", reduced: true) == .still)
        #expect(tick("5m left", "4m left", light: true) == .fade)
    }

    @Test func aLabelDoesNotRollWhenItFirstAppearsOrIsNotSeen() {
        #expect(tick("", "5m left") == .still)
        #expect(tick("5m left", "4m left", same: false) == .still)
        #expect(tick("5m left", "4m left", shown: false) == .still)
        #expect(tick("4m left", "4m left") == .still)
    }

    @Test func aShownLabelRollsOnlyItsChangedDigitsUpFromBelowWhenTheNumberGrows() {
        let word = label()
        word.roll("9m left", for: "call")
        let first = pieces(word).count

        word.roll("10m left", for: "call")
        word.window?.contentView?.layoutSubtreeIfNeeded()
        let whole = word.measure(width: .greatestFiniteMagnitude).width

        #expect(first == 0)
        #expect(pieces(word).allSatisfy { $0.layer?.masksToBounds == true && $0.clipsToBounds })
        #expect((coming(word) + leaving(word)).allSatisfy { $0.frame.maxX < whole / 2 })
        #expect(word.text == "10m left")
        #expect(word.rolled?.busy == true)
        #expect(pieces(word).count == 3)
        #expect(coming(word).count == 1)
        #expect(leaving(word).count == 1)
        #expect((coming(word).first.flatMap(rise) ?? 0) > 0)
        #expect((leaving(word).first.flatMap(rise) ?? 0) > 0)
        #expect(word.intrinsicContentSize.width > 0)
    }

    @Test func aShownLabelRollsItsNewDigitsDownFromAboveWhenTheNumberShrinks() {
        let word = label()
        word.roll("10m left", for: "call")

        word.roll("9m left", for: "call")
        word.window?.contentView?.layoutSubtreeIfNeeded()

        #expect(word.text == "9m left")
        #expect((coming(word).first.flatMap(rise) ?? 0) < 0)
    }

    @Test func underReduceMotionALabelChangesAtOnce() {
        Store.settings.set(true, forKey: "motion.testReduced")
        let word = label()
        word.roll("5m left", for: "call")

        word.roll("4m left", for: "call")

        #expect(word.text == "4m left")
        #expect(word.rolled?.busy == false)
    }

    @Test func aLabelNeverRollsOnFirstShowForAnotherThingOrOutOfSight() {
        let word = label()
        word.roll("5m left", for: "call")
        let first = word.rolled?.busy
        word.roll("12m left", for: "another call")
        let other = word.rolled?.busy
        let loose = label(in: false)
        loose.roll("5m left", for: "call")
        loose.roll("4m left", for: "call")
        let hidden = label()
        hidden.roll("5m left", for: "call")
        hidden.isHidden = true
        hidden.roll("4m left", for: "call")
        Store.settings.set(false, forKey: "roll.testShown")
        let away = label()
        away.roll("5m left", for: "call")
        away.roll("4m left", for: "call")

        #expect(first == false)
        #expect(other == false)
        #expect(loose.rolled?.busy == false)
        #expect(hidden.rolled?.busy == false)
        #expect(away.rolled?.busy == false)
        #expect([word.text, loose.text, hidden.text, away.text] == ["12m left", "4m left", "4m left", "4m left"])
    }

    private func centred() -> (NSView, PinMeetingBadgeView) {
        let badge = PinMeetingBadgeView(browser: nil)
        let host = BadgeHost(badge)
        host.frame = NSRect(x: 20, y: 10, width: 120, height: 30)
        let shown = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: .borderless, backing: .buffered, defer: false)
        shown.isReleasedWhenClosed = false
        shown.contentView?.wantsLayer = true
        shown.contentView?.addSubview(host)
        windows.append(shown)
        return (host, badge)
    }

    private func show(_ text: String, on badge: PinMeetingBadgeView, in host: NSView) {
        badge.show(.countdown(text), title: "", for: "meeting")
        host.needsLayout = true
        host.window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func place(of index: Int, in word: KitLabel) -> CGFloat {
        word.convert(NSPoint(x: KitLabel.offsets(word.runs)[index], y: 0), to: nil).x
    }

    private func capsule(_ badge: PinMeetingBadgeView) -> KitBox? {
        badge.subviews.compactMap { $0 as? KitBox }.first { $0.layer?.animation(forKey: "roll.bounds") != nil }
    }

    @Test(arguments: [("9m", "10m"), ("10m", "9m")])
    func aCentredBadgeStartsItsKeptCharactersWhereTheyWereAndGrowsItsCapsuleWithTheRoll(_ old: String, _ new: String) throws {
        let (host, badge) = centred()
        show(old, on: badge, in: host)
        let word = try #require(badge.content as? KitLabel)
        let before = place(of: old.count - 1, in: word)
        let first = place(of: 0, in: word)
        let oldRuns = word.runs
        let wide = badge.frame.width

        show(new, on: badge, in: host)
        let kept = pieces(word).filter { $0.layer?.animation(forKey: "glide.position") != nil && $0.layer?.animation(forKey: "glide.opacity") == nil }
        let slide = try #require(kept.first?.layer?.animation(forKey: "glide.position") as? CABasicAnimation)
        let from = try #require((slide.fromValue as? NSValue)?.pointValue)
        let to = try #require((slide.toValue as? NSValue)?.pointValue)
        let began = place(of: new.count - 1, in: word) + (from.x - to.x)
        let ground = try #require(capsule(badge))
        let grow = try #require(ground.layer?.animation(forKey: "roll.bounds") as? CABasicAnimation)
        let grewFrom = try #require((grow.fromValue as? NSValue)?.rectValue)

        #expect(kept.count == 1)
        #expect(abs(began - before) < 0.5)
        #expect(abs((leaving(word).first.map { start(of: 0, in: $0, runs: oldRuns) } ?? .infinity) - first) < 0.5)
        #expect(abs(grow.duration - slide.duration) < 0.0001)
        #expect(abs(grewFrom.width - wide) < 0.5)
        #expect(abs(ground.frame.width - badge.frame.width) < 0.5)
        #expect(ground.layer?.animation(forKey: "roll.position") != nil)
    }

    private func start(of index: Int, in piece: NSView, runs: [KitLabel.Run]) -> CGFloat {
        guard let copy = piece.subviews.first else { return .infinity }
        return copy.convert(NSPoint(x: KitLabel.offsets(runs)[index], y: 0), to: nil).x
    }

    @Test func aChipAnchoredOnItsRightRollsItsLeavingDigitOutFromWhereItWasAndGrowsWithTheRoll() throws {
        let chip = SideCountView()
        let host = ChipHost(chip)
        host.frame = NSRect(x: 20, y: 10, width: 120, height: 30)
        let shown = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: .borderless, backing: .buffered, defer: false)
        shown.isReleasedWhenClosed = false
        shown.contentView?.wantsLayer = true
        shown.contentView?.addSubview(host)
        windows.append(shown)
        chip.count = 9
        chip.fold(true, curve: .none)
        host.needsLayout = true
        shown.contentView?.layoutSubtreeIfNeeded()
        let tally = try #require(chip.subviews.compactMap { $0 as? KitBox }.first?.subviews.compactMap { $0 as? KitLabel }.first)
        let was = place(of: 0, in: tally)
        let oldRuns = tally.runs
        let wide = chip.frame.width

        chip.count = 10
        host.needsLayout = true
        shown.contentView?.layoutSubtreeIfNeeded()
        let gone = try #require(leaving(tally).first)
        let box = try #require(chip.subviews.compactMap { $0 as? KitBox }.first)
        let grow = try #require(box.layer?.animation(forKey: "roll.bounds") as? CABasicAnimation)
        let grewFrom = try #require((grow.fromValue as? NSValue)?.rectValue)

        #expect(chip.frame.width > wide)
        #expect(abs(start(of: 0, in: gone, runs: oldRuns) - was) < 0.5)
        #expect(abs(grewFrom.width - wide) < 0.5)
        #expect(coming(tally).count == 1)
    }

    @Test func aLabelMovedWithItsRowRidesAlongInsteadOfStayingBehind() {
        let word = label()
        word.roll("4", for: "folder")
        word.window?.contentView?.layoutSubtreeIfNeeded()
        word.roll("5", for: "folder")
        let made = pieces(word).map(\.frame)

        word.setFrameOrigin(NSPoint(x: word.frame.minX + 30, y: word.frame.minY + 30))
        word.window?.contentView?.layoutSubtreeIfNeeded()

        #expect(!made.isEmpty)
        #expect(pieces(word).map(\.frame) == made)
        #expect(pieces(word).allSatisfy { piece in
            guard let move = piece.layer?.animation(forKey: "glide.position") as? CABasicAnimation,
                  let from = (move.fromValue as? NSValue)?.pointValue, let to = (move.toValue as? NSValue)?.pointValue else { return true }
            return abs(from.x - to.x) < 0.01
        })
    }

    @Test func underReduceMotionACentredBadgeChangesAtOnce() throws {
        Store.settings.set(true, forKey: "motion.testReduced")
        let (host, badge) = centred()
        show("9m", on: badge, in: host)

        show("10m", on: badge, in: host)
        let word = try #require(badge.content as? KitLabel)

        #expect(word.text == "10m")
        #expect(word.rolled?.busy == false)
        #expect(capsule(badge) == nil)
    }

    @Test func theSameTextAgainChangesNothing() {
        let word = label()
        word.roll("3", for: "folder")
        word.roll("4", for: "folder")
        let rolling = pieces(word).count

        word.roll("4", for: "folder")

        #expect(rolling > 0)
        #expect(pieces(word).count == rolling)
    }
}

private final class BadgeHost: NSView {
    let badge: PinMeetingBadgeView

    init(_ badge: PinMeetingBadgeView) {
        self.badge = badge
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(badge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let size = badge.intrinsicContentSize
        badge.frame = NSRect(x: ((bounds.width - size.width) / 2 * 2).rounded() / 2, y: 4, width: size.width, height: size.height)
    }
}

private final class ChipHost: NSView {
    let chip: SideCountView

    init(_ chip: SideCountView) {
        self.chip = chip
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(chip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = chip.width
        chip.kitSetFrame(NSRect(x: bounds.width - 10 - width, y: 6, width: width, height: SideCountView.height))
    }
}
