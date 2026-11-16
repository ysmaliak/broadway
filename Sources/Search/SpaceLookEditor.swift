import AppKit
import Combine
import QuartzCore

enum ThemePad {
    static let height: CGFloat = 168
    static var wide: Bool { NSScreen.screens.contains { $0.canRepresent(.p3) } }
    static var reach: Double { reach(wide) }
    static func reach(_ wide: Bool) -> Double { wide ? 0.32 : 0.24 }
    static let pitch: CGFloat = 10

    static func toneValue(_ colours: [String]) -> Double {
        let l = colours.map { Oklch(hex: $0).l }.reduce(0, +) / Double(max(1, colours.count))
        return min(1, max(0, l))
    }

    static func tone(_ value: Double) -> Double { min(1, max(0, value)) }

    static func toneTrack(_ colours: [String]) -> [NSColor] {
        let first = Oklch(hex: colours.first ?? "808080")
        return stride(from: 0.0, through: 1, by: 0.25).map { Paint.gamut(Oklch(l: tone($0), c: first.c, h: first.h)).color }
    }

    static func retoned(_ colours: [String], _ value: Double) -> [String] {
        let shift = tone(value) - tone(toneValue(colours))
        guard abs(shift) > 0.0005 else { return colours }
        return colours.map { hex in
            let source = Oklch(hex: hex)
            return Paint.gamut(Oklch(l: min(1, max(0, source.l + shift)), c: source.c, h: source.h), wide: !source.inGamut).code
        }
    }

    static func partner(for colours: [String]) -> String {
        let last = Oklch(hex: colours.last ?? "808080")
        let c = max(last.c, 0.1)
        return Paint.gamut(Oklch(l: last.l, c: c, h: (last.h + 110).truncatingRemainder(dividingBy: 360)), wide: !last.inGamut).code
    }

    static func room(l: Double, h: Double, wide: Bool = ThemePad.wide) -> Double {
        Paint.gamut(Oklch(l: l, c: reach(wide), h: h), wide: wide).c
    }

    static func place(_ hex: String, in size: CGSize, wide: Bool = ThemePad.wide) -> CGPoint {
        let colour = Oklch(hex: hex)
        let room = room(l: colour.l, h: colour.h, wide: wide)
        let amount = room < 0.001 || colour.c < 0.012 * room / reach(wide) ? 0 : min(1, colour.c / room)
        let angle = colour.h * .pi / 180
        return CGPoint(x: size.width / 2 + cos(angle) * amount * size.width / 2,
                       y: size.height / 2 - sin(angle) * amount * size.height / 2)
    }

    static func colour(at point: CGPoint, in size: CGSize, lightness: Double, wide: Bool = ThemePad.wide) -> Oklch {
        let (amount, angle) = polar(point, in: size)
        return Paint.gamut(Oklch(l: lightness, c: amount * room(l: lightness, h: angle, wide: wide), h: angle), wide: wide)
    }

    static func shade(at point: CGPoint, in size: CGSize, lightness: Double) -> Oklch {
        let (amount, angle) = polar(point, in: size)
        return Paint.gamut(Oklch(l: lightness, c: amount * reach, h: angle), wide: wide)
    }

    private static func polar(_ point: CGPoint, in size: CGSize) -> (amount: Double, angle: Double) {
        let x = (point.x - size.width / 2) / (size.width / 2)
        let y = -(point.y - size.height / 2) / (size.height / 2)
        var angle = atan2(y, x) * 180 / .pi
        if angle < 0 { angle += 360 }
        return (min(1, hypot(x, y)), angle)
    }

    static func spoken(_ colours: [String]) -> String {
        colours.map { $0.hasPrefix("p3:") ? "Display P3 #\($0.dropFirst(3))" : "#\($0)" }.joined(separator: ", ")
    }
}

enum LookInk {
    static func primary(_ opacity: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let base = NSColor.labelColor.kitResolved(dark: dark)
            return base.withAlphaComponent(base.alphaComponent * opacity)
        }
    }

    static let softRing = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? NSColor(white: 1, alpha: 0.26) : NSColor(white: 0, alpha: 0.14)
    }

    static func white(_ level: Double) -> NSColor {
        NSColor(srgbRed: CGFloat(level), green: CGFloat(level), blue: CGFloat(level), alpha: 1)
    }

    static func scale(_ amount: CGFloat, in bounds: CGRect) -> CATransform3D {
        guard amount != 1 else { return CATransform3DIdentity }
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0),
                                                       CATransform3DMakeScale(amount, amount, 1)),
                                   CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0))
    }

    static func snap(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
        (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }
}

class StillLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

final class StillShape: CAShapeLayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

final class StillGradient: CAGradientLayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

final class SpaceLookEditorView: NSView {
    static let width: CGFloat = 336
    static let shut: CGFloat = 400
    static let room: CGFloat = 322
    static let open: CGFloat = shut + room
    static let moreKey = "look.more"
    private static let left: CGFloat = 17
    private static let span: CGFloat = 300
    private static let slider: CGFloat = 85
    private static let fold: CGFloat = 388
    private static let gridTop: CGFloat = 238
    private static let columns = 6

    let browser: Browser
    var settle: ((() -> Void) -> Void)?
    var resized: ((NSSize) -> Void)?

    private(set) var editingDark: Bool
    private(set) var moreOpen: Bool
    private(set) var folded: CGFloat
    private var folding: FloatTween?

    private var focus = 0 { didSet { if focus != oldValue { shown = nil } } }
    private var toneBase: [String]? { didSet { if toneBase != oldValue { shown = nil } } }
    private lazy var reads = KitReads { [weak self] in self?.queue() }
    private var queued = false
    private var shown: (look: SpaceLook, name: String, icon: TabIcon, dark: Bool, editing: Bool)?
    private var motion: KitCurve = .none

    private let iconButton = KitButton(.plain(press: 1), label: "Change Icon")
    private let iconGround = KitBox(fill: .quaternarySystemFill, corners: .radius(8))
    private let iconSymbol = KitSymbol("square.dashed", style: KitSymbol.Style(size: 15, weight: .medium), tint: .labelColor)
    private let iconEmoji = KitLabel("", font: .systemFont(ofSize: 12), color: .labelColor)
    private let name = KitLabel("", font: .systemFont(ofSize: 15, weight: .semibold), color: .labelColor)
    private let options = KitButton(.plain(press: 1), label: "Space Look Options")
    private let modes = KitChoice("Colour", options: [KitChoice.Option(title: "One Colour"), KitChoice.Option(title: "Light and Dark")], picked: 1)
    private let previews = [LookSidePreview(dark: false), LookSidePreview(dark: true)]
    private let sideNames = [KitLabel("Light", font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor),
                             KitLabel("Dark", font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)]
    private let tags = [KitLabel("Matched", font: .systemFont(ofSize: 11), color: .tertiaryLabelColor),
                        KitLabel("Matched", font: .systemFont(ofSize: 11), color: .tertiaryLabelColor)]
    private let match = KitButton(title: "Match Dark", font: .systemFont(ofSize: 11, weight: .medium), look: .plain(press: 0.94))
    private let grid = KitFlippedView()
    private var tiles: [LookSwatchTile] = []
    private let intensity = LookTrackSlider(label: "Intensity", notch: SpaceLook.knee, spoken: SpaceLook.spoken)
    private let moreRow = LookFoldRow(title: "More")
    private let box = KitFlippedView()
    private let pad = LookPadView()
    private var dots: [LookDotButton] = []
    private let add = LookSmallButton(symbol: "plus", help: "Add Colour")
    private let remove = LookSmallButton(symbol: "minus", help: "Remove Colour")
    private let well = NSColorWell(style: .default)
    private let tone = LookTrackSlider(label: "Tone")
    private let clear = LookClearSlider()
    private let grain = LookGrainSlider()
    private var captions: [(KitLabel, NSView, CGFloat, CGFloat?)] = []

    init(browser: Browser, dark: Bool? = nil) {
        self.browser = browser
        let now = dark ?? browser.window?.contentView?.kitDark ?? (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        editingDark = now
        let look = browser.space.look ?? SpaceLook()
        moreOpen = Store.settings.bool(forKey: Self.moreKey) || Self.needsMore(look)
        folded = moreOpen ? 1 : 0
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.shut + Self.room * folded))
        build()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { size }

    var size: NSSize {
        NSSize(width: Self.width, height: LookInk.snap(Self.shut + Self.room * folded, window?.backingScaleFactor ?? 2))
    }

    static func needsMore(_ look: SpaceLook) -> Bool {
        if look.transparency > 0 || look.glass || look.grain > 0 { return true }
        return [look.side(dark: true), look.side(dark: false)].contains { tone in
            tone.colour == "custom" && SpaceLook.swatch(for: tone) == nil
        }
    }

    private var look: SpaceLook { browser.space.look ?? SpaceLook() }
    private var side: SpaceLook.Tone { look.side(dark: editingDark) }
    private var shade: Bool { look.shade(dark: editingDark) }
    private var colours: [String] { side.picked }
    private var shownFocus: Int { min(focus, colours.count - 1) }

    private func build() {
        let mark = NSView()
        iconButton.content = mark
        mark.addSubview(iconGround)
        mark.addSubview(iconSymbol)
        mark.addSubview(iconEmoji)
        iconButton.kitAccess(help: "Change Icon")
        iconButton.action = { [weak self] in
            guard let self else { return }
            browser.editingLook = false
            browser.iconPicker.pick(.space(browser.space.id))
        }
        addSubview(iconButton)
        name.setAccessibilityElement(true)
        addSubview(name)
        options.content = KitSymbol("ellipsis", style: KitSymbol.Style(size: 13), tint: .labelColor)
        options.kitAccess(help: "Space Look Options")
        options.action = { [weak self] in self?.showMenu() }
        addSubview(options)

        modes.pick = { [weak self] index in
            guard let self else { return }
            settling { self.change { $0.choose(oneColour: index == 0, dark: self.editingDark) } }
        }
        addSubview(modes)
        for (index, preview) in previews.enumerated() {
            preview.action = { [weak self] in self?.edit(dark: index == 1) }
            addSubview(preview)
            addSubview(sideNames[index])
            addSubview(tags[index])
            sideNames[index].setAccessibilityElement(false)
            tags[index].setAccessibilityElement(false)
        }
        match.action = { [weak self] in
            guard let self else { return }
            settling { self.change { $0.follow(dark: self.editingDark) } }
        }
        (match.content as? KitLabel)?.color = .secondaryLabelColor
        addSubview(match)

        grid.setAccessibilityElement(true)
        grid.setAccessibilityRole(.radioGroup)
        addSubview(grid)
        for (index, swatch) in SpaceLook.swatches.enumerated() {
            let tile = LookSwatchTile(swatch: swatch)
            tile.action = { [weak self] in
                guard let self else { return }
                focus = 0
                settling { self.repaint { $0 = swatch.tone } }
            }
            tile.step = { [weak self] by in self?.step(from: index, by: by) }
            tiles.append(tile)
            grid.addSubview(tile)
        }

        intensity.moved = { [weak self] value in
            self?.repaint(lasting: false) { now in
                now = SpaceLook.Tone(colours: now.picked, intensity: SpaceLook.intensity(at: value))
            }
        }
        intensity.ended = { [weak self] in self?.settled() }
        addSubview(intensity)

        moreRow.action = { [weak self] in
            guard let self else { return }
            setMore(!moreOpen)
        }
        addSubview(moreRow)

        box.wantsLayer = true
        box.layer?.masksToBounds = true
        addSubview(box)

        pad.grabbed = { [weak self] index in
            self?.focus = index
            self?.refresh()
        }
        pad.moved = { [weak self] index, hex in
            guard let self else { return }
            var next = colours
            guard next.indices.contains(index) else { return }
            next[index] = hex
            recolour(next)
        }
        pad.ended = { [weak self] in self?.settled() }
        box.addSubview(pad)

        add.action = { [weak self] in
            guard let self else { return }
            focus = colours.count
            settling { self.recolour(lasting: true, self.colours + [ThemePad.partner(for: self.colours)]) }
        }
        remove.action = { [weak self] in
            guard let self else { return }
            var next = colours
            next.remove(at: shownFocus)
            focus = max(0, shownFocus - 1)
            settling { self.recolour(lasting: true, next) }
        }
        box.addSubview(add)
        box.addSubview(remove)
        well.kitAccess(help: "Pick Exactly")
        well.kitOnChange { [weak self] control in
            guard let self, let picked = (control as? NSColorWell)?.color else { return }
            var next = colours
            next[shownFocus] = picked.code
            recolour(lasting: true, next)
        }
        box.addSubview(well)

        tone.moved = { [weak self] value in
            guard let self else { return }
            let base = toneBase ?? colours
            toneBase = base
            recolour(ThemePad.retoned(base, value))
        }
        tone.ended = { [weak self] in
            self?.toneBase = nil
            self?.settled()
            self?.refresh()
        }
        box.addSubview(tone)

        clear.moved = { [weak self] value, glass in
            guard let self else { return }
            let snapping = glass && !look.glass
            let apply = {
                self.change(lasting: false) {
                    $0.transparency = value
                    $0.glass = glass
                }
            }
            if snapping { settling(apply) } else { apply() }
        }
        clear.ended = { [weak self] in self?.settled() }
        grain.moved = { [weak self] value in self?.change(lasting: false) { $0.grain = value } }
        grain.ended = { [weak self] in self?.settled() }
        box.addSubview(clear)
        box.addSubview(grain)

        caption("Colour", in: self, y: 214)
        caption("Intensity", in: self, y: 324, row: 24)
        caption("Tone", in: box, y: 222, row: 24)
        caption("Clear", in: box, y: 258, row: 26)
        caption("Grain", in: box, y: 294, row: 24)
        nextKeys()
    }

    private func caption(_ text: String, in holder: NSView, y: CGFloat, row: CGFloat? = nil) {
        let label = KitLabel(text, font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor)
        holder.addSubview(label)
        captions.append((label, holder, y, row))
    }

    private func nextKeys() {
        let order: [NSView] = [iconButton, options, modes] + previews + [match] + tiles + [intensity, moreRow, pad, add, remove, well, tone, clear, grain]
        for (view, next) in zip(order, order.dropFirst()) { view.nextKeyView = next }
    }

    func pickMode(oneColour: Bool) {
        modes.picked = oneColour ? 0 : 1
        modes.pick?(modes.picked)
    }

    func pickSide(dark: Bool) { previews[dark ? 1 : 0].action?() }

    func pickSwatch(_ id: String) { tiles.first { $0.swatch.id == id }?.action?() }

    private func step(from index: Int, by: Int) {
        let next = index + by
        guard tiles.indices.contains(next) else { return }
        window?.makeFirstResponder(tiles[next])
    }

    private func edit(dark: Bool) {
        guard !look.oneColour, dark != editingDark else { return }
        editingDark = dark
        focus = 0
        shown = nil
        motion = Motion.kitQuick
        refresh()
        motion = .none
    }

    private func change(lasting: Bool = true, _ edit: (inout SpaceLook) -> Void) {
        var next = look
        edit(&next)
        browser.setSpaceLook(browser.space.id, to: next, lasting: lasting)
        refresh()
    }

    private func repaint(lasting: Bool = true, _ edit: (inout SpaceLook.Tone) -> Void) {
        let dark = editingDark
        var next = side
        edit(&next)
        change(lasting: lasting) { $0.paint(next, dark: dark) }
    }

    private func settled() { browser.setSpaceLook(browser.space.id, to: look, lasting: true) }

    private func recolour(lasting: Bool = false, _ colours: [String]) {
        repaint(lasting: lasting) { now in
            let strength = now.colour == "custom" ? now.intensity ?? SpaceLook.bold : SpaceLook.bold
            now = SpaceLook.Tone(colours: colours, intensity: strength)
        }
    }

    private func settling(_ body: @escaping () -> Void) {
        motion = Motion.kitSettle
        if let settle { settle(body) } else { body() }
        motion = .none
    }

    func setMore(_ open: Bool) {
        guard open != moreOpen else { return }
        moreOpen = open
        Store.settings.set(open, forKey: Self.moreKey)
        folding?.cancel()
        folding = nil
        let from = folded
        let to: CGFloat = open ? 1 : 0
        guard !Motion.reduced, window != nil else {
            folded = to
            grew()
            return
        }
        let shape = Motion.fold(out: open)
        let spring = KitSpring(response: shape.response, damping: shape.damping)
        let duration = spring.animation("opacity", from: 0, to: 1).settlingDuration
        folding = FloatTween.run(on: self, duration: duration, step: { [weak self] seconds in
            guard let self else { return }
            folded = from + (to - from) * CGFloat(spring.progress(Double(seconds)))
            grew()
        }, done: { [weak self] in
            guard let self else { return }
            folded = to
            folding = nil
            grew()
        })
    }

    static var heights: [Double] = []

    private func grew() {
        let now = size
        if Store.testing { Self.heights.append(Double(now.height)) }
        if frame.size != now { setFrameSize(now) }
        resized?(now)
        invalidateIntrinsicContentSize()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func showMenu() {
        let here = browser.space.id
        let now = look
        KitMenu.pop([
            .action("Reset", key: "", modifiers: []) { [weak self] in
                guard let self else { return }
                settling { if self.browser.space.id == here { self.change { $0 = SpaceLook() } } else { self.browser.setSpaceLook(here, to: SpaceLook()) } }
            },
            .action("Use for All Spaces", key: "", modifiers: []) { [weak self] in self?.browser.useLookEverywhere(now) },
        ], below: options)
    }

    private func queue() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            self?.queued = false
            self?.refresh()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    func refresh() {
        reads.track { refreshNow() }
    }

    private func refreshNow() {
        let here = browser.space
        let now = look
        let dark = kitDark
        if let shown, shown.look == now, shown.name == here.name, shown.icon == here.shownIcon, shown.dark == dark,
           shown.editing == editingDark, dots.count == now.side(dark: editingDark).picked.count { return }
        shown = (now, here.name, here.shownIcon, dark, editingDark)
        apply(now, space: here)
    }

    private func apply(_ now: SpaceLook, space: Space) {
        let one = now.oneColour
        let side = now.side(dark: editingDark)
        let shade = now.shade(dark: editingDark)
        let colours = side.picked
        let lit = shownFocus
        let icon = space.shownIcon
        if let emoji = icon.emoji, !emoji.isEmpty {
            iconEmoji.text = emoji
            iconEmoji.isHidden = false
            iconSymbol.isHidden = true
        } else {
            iconSymbol.name = icon.symbol ?? "square.dashed"
            iconSymbol.isHidden = false
            iconEmoji.isHidden = true
        }
        name.text = space.name

        modes.picked = one ? 0 : 1
        let editing = editingDark ? "Dark" : "Light"
        for (index, preview) in previews.enumerated() {
            let dark = index == 1
            let marked = !one && dark == editingDark
            let follows = !one && now.follows(dark: dark)
            preview.show(now, editing: marked, curve: motion)
            preview.action = one ? nil : { [weak self] in self?.edit(dark: dark) }
            preview.setAccessibilityValue(one ? "Same in light and dark" : marked ? (follows ? "Editing, matched" : "Editing") : (follows ? "Matched" : ""))
            preview.setAccessibilitySelected(marked)
            tags[index].isHidden = !follows || (marked && !now.follows(dark: !dark))
        }
        let other = editingDark ? "Light" : "Dark"
        let matchable = !one && !now.follows(dark: editingDark) && !now.follows(dark: !editingDark)
        match.isHidden = !matchable
        (match.content as? KitLabel)?.text = "Match \(other)"
        match.setAccessibilityLabel("Match \(other)")
        match.kitAccess(help: "\(editing) follows \(other) again")
        tags[editingDark ? 1 : 0].isHidden = tags[editingDark ? 1 : 0].isHidden || matchable

        grid.setAccessibilityLabel(one ? "Colour" : "Colour for \(editing)")
        for tile in tiles { tile.set(on: tile.swatch.tone == side, dark: shade) }

        let first = colours[0]
        func at(_ intensity: Double) -> NSColor { Paint.ground([first], intensity: intensity, dark: shade).stops[0].color }
        intensity.show(value: SpaceLook.position(of: side.colour == "custom" ? side.strength : SpaceLook.calm),
                       track: [at(0), at(1), at(SpaceLook.real)], locations: [0, SpaceLook.knee, 1], curve: motion)
        intensity.name = one ? "Intensity" : "Intensity for \(editing)"

        moreRow.show(open: moreOpen)

        pad.show(colours, focus: lit, curve: motion)
        while dots.count < colours.count {
            let index = dots.count
            let dot = LookDotButton(index: index)
            dot.action = { [weak self] in
                self?.focus = index
                self?.refresh()
            }
            dots.append(dot)
            box.addSubview(dot)
        }
        while dots.count > colours.count { dots.removeLast().removeFromSuperview() }
        for (index, dot) in dots.enumerated() { dot.set(colour: colours[index], on: index == lit) }
        add.isHidden = colours.count >= 3
        remove.isHidden = colours.count <= 1
        well.color = NSColor(hexString: colours[lit])
        tone.show(value: ThemePad.toneValue(colours), track: ThemePad.toneTrack(toneBase ?? colours), locations: nil, curve: motion)
        clear.show(value: now.transparency, glass: now.glass, curve: motion)
        grain.show(value: now.grain)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let x = Self.left
        let scale = window?.backingScaleFactor ?? 2
        iconButton.frame = NSRect(x: x, y: 18, width: 30, height: 30)
        iconGround.frame = iconButton.bounds
        iconSymbol.frame = iconButton.bounds
        let emoji = iconEmoji.intrinsicContentSize
        iconEmoji.frame = NSRect(x: (30 - emoji.width) / 2, y: 7, width: emoji.width, height: 16)
        let corner = NSRect(x: x + Self.span - 24, y: 21, width: 24, height: 24)
        options.frame = corner
        let title = name.intrinsicContentSize
        name.frame = NSRect(x: x + 38, y: 23.5, width: min(title.width, corner.minX - x - 38), height: title.height)

        modes.frame = NSRect(x: x, y: 62, width: Self.span, height: KitChoice.height)
        let half = (Self.span - 10) / 2
        for (index, preview) in previews.enumerated() {
            let left = x + CGFloat(index) * (half + 10)
            preview.frame = NSRect(x: left - 3, y: 101, width: half + 6, height: 80)
            let label = sideNames[index].intrinsicContentSize
            sideNames[index].frame = NSRect(x: left + 2, y: 184, width: label.width, height: label.height)
            let tag = tags[index].intrinsicContentSize
            tags[index].frame = NSRect(x: left + half - 2 - tag.width, y: 184, width: tag.width, height: tag.height)
        }
        let matchSize = match.intrinsicContentSize
        let edited = x + CGFloat(editingDark ? 1 : 0) * (half + 10)
        match.frame = NSRect(x: edited + half - matchSize.width - 2, y: 182, width: matchSize.width, height: 18)

        grid.frame = NSRect(x: x, y: Self.gridTop, width: Self.span, height: 72)
        let across = CGFloat(Self.columns)
        let cell = (Self.span - (across - 1) * 8) / across
        for (index, tile) in tiles.enumerated() {
            let left = LookInk.snap(CGFloat(index % Self.columns) * (cell + 8), scale)
            let right = LookInk.snap(CGFloat(index % Self.columns) * (cell + 8) + cell, scale)
            tile.frame = NSRect(x: left, y: CGFloat(index / Self.columns) * 40, width: right - left, height: 32)
        }

        let wide = Self.span - (Self.slider - x)
        intensity.frame = NSRect(x: Self.slider, y: 324, width: wide, height: 24)
        moreRow.frame = NSRect(x: x - 6, y: 358, width: Self.span + 12, height: 28)

        box.frame = NSRect(x: 0, y: Self.fold, width: Self.width, height: max(0, bounds.height - Self.fold))
        box.alphaValue = min(1, max(0, folded * 1.6 - 0.3))
        box.isHidden = folded <= 0.001
        moreRow.turn(min(1, max(0, folded)))
        pad.frame = NSRect(x: x, y: 8, width: Self.span, height: ThemePad.height)
        var cursor = x
        for dot in dots {
            dot.frame = NSRect(x: cursor, y: 186, width: 24, height: 24)
            cursor += 32
        }
        for button in [add, remove] where !button.isHidden {
            button.frame = NSRect(x: cursor, y: 187, width: 22, height: 22)
            cursor += 30
        }
        well.frame = NSRect(x: x + Self.span - 48, y: 186, width: 48, height: 24)
        tone.frame = NSRect(x: Self.slider, y: 222, width: wide, height: 24)
        clear.frame = NSRect(x: Self.slider, y: 258, width: wide, height: 26)
        grain.frame = NSRect(x: Self.slider, y: 294, width: wide, height: 24)
        for (label, _, y, row) in captions {
            let size = label.intrinsicContentSize
            label.frame = NSRect(x: x, y: y + ((row ?? size.height) - size.height) / 2, width: size.width, height: size.height)
        }
    }
}

final class LookSidePreview: KitButton {
    let dark: Bool
    private let holder = KitFlippedView()
    private let face = KitFlippedView()
    private let ground: SpaceGroundView
    private let lights: [KitBox] = (0..<3).map { _ in KitBox(fill: nil, corners: .capsule) }
    private let rows: [KitBox] = (0..<4).map { _ in KitBox(fill: nil, corners: .capsule) }
    private let sheet = KitBox(fill: nil, corners: .radius(5))
    private let rim = KitBox(fill: nil, corners: .radius(9))
    private let ring = KitBox(fill: nil, corners: .radius(11))
    private var painted = SpaceLook()
    private var editing = false

    init(dark: Bool) {
        self.dark = dark
        ground = SpaceGroundView(look: SpaceLook(), opaque: true)
        super.init(.plain(press: 0.97), label: dark ? "Dark" : "Light")
        ground.spansWindow = false
        ground.staged = true
        ground.groundDark = dark
        face.wantsLayer = true
        face.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        face.layer?.cornerRadius = 9
        face.layer?.cornerCurve = .continuous
        face.layer?.masksToBounds = true
        face.addSubview(ground)
        for part in lights + rows + [sheet] { face.addSubview(part) }
        holder.addSubview(face)
        holder.addSubview(rim)
        holder.addSubview(ring)
        ring.strokeWidth = 2
        ring.alphaValue = 0
        content = holder
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ look: SpaceLook, editing: Bool, curve: KitCurve) {
        let changed = look != painted
        let marked = editing != self.editing
        painted = look
        self.editing = editing
        if changed, curve.animates { face.layer?.kitTransition(curve) }
        ground.blend = LookBlend(from: look)
        let lightInk = look.inkLight(dark: dark)
        for (light, colour) in zip(lights, [NSColor.systemRed, .systemYellow, .systemGreen]) {
            light.fill = colour.withAlphaComponent(0.85).kitResolved(dark: dark)
        }
        for (index, row) in rows.enumerated() {
            row.fill = NSColor(white: lightInk ? 1 : 0, alpha: index == 1 ? 0.5 : 0.2)
        }
        sheet.fill = look.page(dark: dark).flat
        sheet.stroke = NSColor(white: lightInk ? 1 : 0, alpha: 0.08)
        rim.stroke = NSColor(white: lightInk ? 1 : 0, alpha: lightInk ? 0.14 : 0.1)
        ring.stroke = LookInk.primary(0.85)
        ring.layer?.kitAnimate("opacity", to: editing ? 1 : 0, curve: marked ? Motion.kitQuick : .none)
        ring.alphaValue = editing ? 1 : 0
    }

    override func layout() {
        super.layout()
        holder.frame = bounds
        let inner = bounds.insetBy(dx: 3, dy: 3)
        face.frame = inner
        rim.frame = inner
        ring.frame = bounds
        ground.frame = face.bounds
        let h = face.bounds.height
        let w = face.bounds.width
        for (index, light) in lights.enumerated() {
            light.frame = NSRect(x: 8 + CGFloat(index) * 7, y: 8, width: 4.5, height: 4.5)
        }
        let column = w * 0.36
        for (index, row) in rows.enumerated() {
            let width = column - 16 - CGFloat(index == 1 ? 0 : index * 5)
            row.frame = NSRect(x: 8, y: 22 + CGFloat(index) * 11, width: max(12, width), height: 6)
        }
        sheet.frame = NSRect(x: column, y: 6, width: w - column - 6, height: h - 12)
    }
}

final class LookSwatchTile: KitButton {
    let swatch: SpaceLook.Swatch
    var step: ((Int) -> Void)?
    private let face = LookTileFace()
    private var on = false

    init(swatch: SpaceLook.Swatch) {
        self.swatch = swatch
        super.init(.plain(press: 0.94), label: swatch.name)
        content = face
        kitAccess(id: "look.swatch.\(swatch.id)", help: swatch.name)
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(on: Bool, dark: Bool) {
        let changed = on != self.on
        self.on = on
        let ground = swatch.tone.ground(dark: dark)
        face.paint(stops: LookBlend.three(ground), ink: LookInk.white(ground.lightInk ? Paint.lightInk : Paint.darkInk))
        face.mark(on: on, hovering: hovering, curve: changed ? Motion.kitQuick : .none)
        setAccessibilitySelected(on)
        setAccessibilityValue(on ? 1 : 0)
        scale()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: step?(-1)
        case 124: step?(1)
        case 125: step?(6)
        case 126: step?(-6)
        default: super.keyDown(with: event)
        }
    }

    override func hoverChanged() {
        super.hoverChanged()
        face.mark(on: on, hovering: hovering, curve: Motion.kitQuick)
        scale()
    }

    override func layout() {
        super.layout()
        scale(curve: .none)
    }

    private func scale(curve: KitCurve = Motion.kitQuick) {
        guard let layer = face.layer else { return }
        let amount: CGFloat = hovering && !on && !Motion.reduced ? 1.06 : 1
        layer.kitAnimate("transform", to: NSValue(caTransform3D: LookInk.scale(amount, in: face.bounds)), curve: curve, key: "hover")
    }
}

final class LookFoldRow: KitButton {
    private let holder = KitFlippedView()
    private let label: KitLabel
    private let chevron = KitSymbol("chevron.right", style: KitSymbol.Style(size: 10, weight: .semibold), tint: .secondaryLabelColor)
    private let wash = KitBox(fill: nil, corners: .radius(7))
    private var open = false

    init(title: String) {
        label = KitLabel(title, font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor)
        super.init(.plain(press: 0.98), label: title)
        holder.addSubview(wash)
        holder.addSubview(label)
        holder.addSubview(chevron)
        chevron.wantsLayer = true
        label.setAccessibilityElement(false)
        content = holder
        setAccessibilityRole(.disclosureTriangle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(open: Bool) {
        self.open = open
        setAccessibilityValue(open ? 1 : 0)
        setAccessibilityExpanded(open)
    }

    func turn(_ share: CGFloat) {
        guard let layer = chevron.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = chevron.bounds
        layer.transform = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0),
                                                                  CATransform3DMakeRotation(.pi / 2 * share, 0, 0, 1)),
                                              CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0))
        CATransaction.commit()
    }

    override func hoverChanged() {
        super.hoverChanged()
        wash.fill = hovering ? LookInk.primary(0.05) : nil
    }

    override func layout() {
        super.layout()
        holder.frame = bounds
        wash.frame = bounds
        let text = label.intrinsicContentSize
        label.frame = NSRect(x: 6, y: (bounds.height - text.height) / 2, width: text.width, height: text.height)
        let mark = chevron.intrinsicContentSize
        chevron.frame = NSRect(x: bounds.width - 6 - 12 + (12 - mark.width) / 2, y: (bounds.height - mark.height) / 2, width: mark.width, height: mark.height)
    }
}

final class LookPadView: NSView {
    var grabbed: (Int) -> Void = { _ in }
    var moved: (Int, String) -> Void = { _, _ in }
    var ended: () -> Void = {}

    private let ground = KitBox(fill: LookInk.primary(0.05), corners: .radius(14))
    private let field = LookDotField()
    private var handles: [LookKnob] = []
    private var colours: [String] = []
    private var focus = 0
    private var held: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(ground)
        addSubview(field)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Colour")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var tone: Double { ThemePad.tone(ThemePad.toneValue(colours)) }

    func show(_ colours: [String], focus: Int, curve: KitCurve) {
        let litChanged = focus != self.focus
        self.colours = colours
        self.focus = focus
        setAccessibilityValue(ThemePad.spoken(colours))
        while handles.count < colours.count {
            let made = LookKnob(opacity: 0.3)
            made.ring.borderColor = NSColor.white.cgColor
            made.zPosition = 1
            layer?.addSublayer(made)
            handles.append(made)
            place(handles.count - 1, curve: .none)
        }
        while handles.count > colours.count { handles.removeLast().removeFromSuperlayer() }
        for index in handles.indices { place(index, curve: litChanged ? Motion.kitQuick : curve) }
        field.show(points: handlePoints, tone: tone)
    }

    private var handlePoints: [CGPoint] { colours.map { ThemePad.place($0, in: bounds.size) } }

    private func place(_ index: Int, curve: KitCurve) {
        let handle = handles[index]
        let lit = index == focus
        let side: CGFloat = lit ? 26 : 20
        let point = ThemePad.place(colours[index], in: bounds.size)
        let scale = window?.backingScaleFactor ?? 2
        let origin = CGPoint(x: LookInk.snap(point.x - side / 2, scale), y: LookInk.snap(point.y - side / 2, scale))
        handle.fill.backgroundColor = NSColor(hexString: colours[index]).cgColor
        let position = CGPoint(x: origin.x + side / 2, y: origin.y + side / 2)
        if handle.bounds.width != side || curve.animates {
            handle.shape(CGSize(width: side, height: side), radius: side / 2, border: lit ? 3 : 2.5, shadow: lit ? 5 : 3,
                         curve: handle.bounds == .zero ? .none : curve)
        }
        handle.kitAnimate("position", to: NSValue(point: position), curve: curve)
    }

    private func press(_ index: Int?) {
        let before = held
        held = index
        for changed in Set([before, index].compactMap { $0 }) where handles.indices.contains(changed) {
            handles[changed].kitAnimate("transform", to: NSValue(caTransform3D: held == changed && !Motion.reduced ? CATransform3DMakeScale(1.12, 1.12, 1) : CATransform3DIdentity),
                                        curve: Motion.kitQuick, key: "held")
        }
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        field.frame = bounds
        for index in handles.indices { place(index, curve: .none) }
        field.show(points: handlePoints, tone: tone)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    private func local(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) {
        let start = local(event)
        let points = handlePoints
        let distances = points.map { hypot($0.x - start.x, $0.y - start.y) }
        let nearest = distances.indices.min { distances[$0] < distances[$1] } ?? 0
        let index = distances.isEmpty ? focus : distances[nearest] < 30 ? nearest : focus
        press(index)
        grabbed(index)
        drag(to: start)
    }

    override func mouseDragged(with event: NSEvent) { drag(to: local(event)) }

    override func mouseUp(with event: NSEvent) {
        press(nil)
        ended()
    }

    private func drag(to point: CGPoint) {
        guard let held else { return }
        moved(held, ThemePad.colour(at: point, in: bounds.size, lightness: tone).code)
    }

    override var acceptsFirstResponder: Bool { KitFocus.takes(!colours.isEmpty) }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
    }

    override func keyDown(with event: NSEvent) {
        let nudge: CGPoint
        switch event.keyCode {
        case 123: nudge = CGPoint(x: -6, y: 0)
        case 124: nudge = CGPoint(x: 6, y: 0)
        case 125: nudge = CGPoint(x: 0, y: 6)
        case 126: nudge = CGPoint(x: 0, y: -6)
        default: return super.keyDown(with: event)
        }
        guard colours.indices.contains(focus) else { return }
        let at = ThemePad.place(colours[focus], in: bounds.size)
        let point = CGPoint(x: min(bounds.width, max(0, at.x + nudge.x)), y: min(bounds.height, max(0, at.y + nudge.y)))
        moved(focus, ThemePad.colour(at: point, in: bounds.size, lightness: tone).code)
        ended()
    }
}

final class LookDotField: NSView {
    private static let slack = 0.002
    private var points: [CGPoint] = []
    private var tone: Double = -1
    private var cache: (tone: Double, size: CGSize, colours: [CGColor])?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(points: [CGPoint], tone: Double) {
        let retoned = abs(tone - self.tone) >= Self.slack
        guard points != self.points || retoned else { return }
        let before = self.points
        self.points = points
        if retoned { self.tone = tone }
        guard !retoned, before.count == points.count else {
            needsDisplay = true
            return
        }
        for (old, new) in zip(before, points) where old != new {
            let reach: CGFloat = 46 + ThemePad.pitch
            setNeedsDisplay(CGRect(x: min(old.x, new.x) - reach, y: min(old.y, new.y) - reach,
                                   width: abs(old.x - new.x) + reach * 2, height: abs(old.y - new.y) + reach * 2))
        }
    }

    private func colours(for size: CGSize) -> [CGColor] {
        if let cache, abs(cache.tone - tone) < Self.slack, cache.size == size { return cache.colours }
        let pitch = ThemePad.pitch
        let lightness = tone * 0.55 + 0.72 * 0.45
        var made: [CGColor] = []
        var y = pitch / 2
        while y < size.height {
            var x = pitch / 2
            while x < size.width {
                made.append(ThemePad.shade(at: CGPoint(x: x, y: y), in: size, lightness: lightness).color.cgColor)
                x += pitch
            }
            y += pitch
        }
        cache = (tone, size, made)
        return made
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let size = bounds.size
        let fills = colours(for: size)
        let pitch = ThemePad.pitch
        var index = 0
        var y = pitch / 2
        while y < size.height {
            guard y + 4 > dirtyRect.minY, y - 4 < dirtyRect.maxY else {
                index += Int(((size.width - pitch / 2) / pitch).rounded(.up))
                y += pitch
                continue
            }
            var x = pitch / 2
            while x < size.width {
                guard x + 4 > dirtyRect.minX, x - 4 < dirtyRect.maxX else {
                    index += 1
                    x += pitch
                    continue
                }
                var near: CGFloat = 0
                for point in points {
                    let dx = x - point.x, dy = y - point.y
                    if abs(dx) < 46, abs(dy) < 46 { near = max(near, 1 - (dx * dx + dy * dy).squareRoot() / 46) }
                }
                let side = 3.2 + 3.2 * near
                context.setFillColor(fills[index])
                context.fillEllipse(in: CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side))
                index += 1
                x += pitch
            }
            y += pitch
        }
    }
}

final class LookDotButton: KitButton {
    private let face = KitBox(fill: nil, corners: .capsule)

    init(index: Int) {
        super.init(.plain(press: 0.94), label: "Colour \(index + 1)")
        let holder = NSView()
        holder.addSubview(face)
        content = holder
        kitAccess(help: "Colour \(index + 1)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(colour: String, on: Bool) {
        face.fill = NSColor(hexString: colour)
        face.stroke = on ? LookInk.primary(0.85) : LookInk.primary(0.15)
        face.strokeWidth = on ? 2 : nil
        setAccessibilitySelected(on)
    }

    override func layout() {
        super.layout()
        face.frame = NSRect(x: 3, y: 3, width: 18, height: 18)
    }
}

final class LookSmallButton: KitButton {
    private let face = KitBox(fill: LookInk.primary(0.07), corners: .capsule)
    private let symbol: KitSymbol

    init(symbol name: String, help: String) {
        symbol = KitSymbol(name, style: KitSymbol.Style(size: 10, weight: .bold), tint: .labelColor)
        super.init(.plain(press: 0.94), label: help)
        let holder = NSView()
        holder.addSubview(face)
        holder.addSubview(symbol)
        content = holder
        kitAccess(help: help)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        face.frame = bounds
        symbol.frame = bounds
    }
}

final class LookTileFace: NSView {
    let label = KitLabel("", font: .systemFont(ofSize: 11, weight: .semibold))
    private let fill = KitBox(fill: nil, corners: .radius(10))
    private let edge = KitBox(fill: nil, corners: .radius(10))
    private let check = KitSymbol("checkmark", style: KitSymbol.Style(size: 9, weight: .bold))

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(fill)
        addSubview(label)
        addSubview(check)
        addSubview(edge)
        label.setAccessibilityElement(false)
        check.wantsLayer = true
        check.alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func paint(stops: [NSColor], ink: NSColor) {
        fill.gradient = stops
        label.color = ink
        label.opacity = 0.9
        check.tint = ink
    }

    func mark(on: Bool, hovering: Bool, curve: KitCurve) {
        let stroke = LookInk.primary(on ? 0.85 : hovering ? 0.22 : 0.08)
        let width: CGFloat? = on ? 2 : nil
        if curve.animates { edge.layer?.kitTransition(curve) }
        edge.stroke = stroke
        edge.strokeWidth = width
        let target: Swift.Float = on ? 1 : 0
        guard let layer = check.layer, layer.opacity != target || layer.animation(forKey: "opacity") != nil else { return }
        let small = NSValue(caTransform3D: LookInk.scale(0.01, in: check.bounds))
        let full = NSValue(caTransform3D: CATransform3DIdentity)
        defer { check.alphaValue = CGFloat(target) }
        guard curve.animates else {
            layer.kitAnimate("opacity", to: target, curve: .none)
            layer.kitAnimate("transform", to: full, curve: .none, key: "mark")
            return
        }
        if on, layer.animation(forKey: "mark") == nil { layer.kitAnimate("transform", to: small, curve: .none, key: "mark") }
        layer.kitAnimate("opacity", to: target, curve: curve)
        layer.kitAnimate("transform", to: on ? full : small, curve: curve, key: "mark")
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        edge.frame = bounds
        fill.gradientAxis = (CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1))
        let text = label.intrinsicContentSize
        label.frame = NSRect(x: 8, y: bounds.height - 6 - text.height, width: min(text.width, bounds.width - 16), height: text.height)
        let mark = check.intrinsicContentSize
        check.frame = NSRect(x: bounds.width - 7 - mark.width, y: 8.5, width: mark.width, height: mark.height)
    }
}

class LookKnob: StillLayer {
    let fill = StillLayer()
    let ring = StillLayer()

    init(opacity: Swift.Float) {
        super.init()
        for part in [fill, ring] {
            part.shadowColor = NSColor.black.cgColor
            part.shadowOpacity = opacity
            part.shadowOffset = CGSize(width: 0, height: 1)
            addSublayer(part)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func shape(_ size: CGSize, radius: CGFloat, border: CGFloat, shadow: CGFloat, curve: KitCurve) {
        let box = CGRect(origin: .zero, size: size)
        let mid = NSValue(point: CGPoint(x: size.width / 2, y: size.height / 2))
        kitAnimate("bounds", to: NSValue(rect: box), curve: curve)
        for part in [fill, ring] {
            part.kitAnimate("bounds", to: NSValue(rect: box), curve: curve)
            part.kitAnimate("position", to: mid, curve: curve)
            part.kitAnimate("cornerRadius", to: radius, curve: curve)
            part.kitAnimate("shadowRadius", to: shadow, curve: curve)
        }
        ring.kitAnimate("borderWidth", to: border, curve: curve)
        fill.kitAnimate("shadowPath", to: CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil), curve: curve)
        ring.kitAnimate("shadowPath", to: Self.annulus(box, radius: radius, width: border), curve: curve)
    }

    static func annulus(_ box: CGRect, radius: CGFloat, width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
        let inner = box.insetBy(dx: width, dy: width)
        let corner = max(0, min(radius - width, min(inner.width, inner.height) / 2))
        var flip = CGAffineTransform(translationX: box.midX * 2, y: 0).scaledBy(x: -1, y: 1)
        path.addPath(CGPath(roundedRect: inner, cornerWidth: corner, cornerHeight: corner, transform: &flip))
        return path
    }
}

final class LookHandle: LookKnob {
    var held = false {
        didSet {
            guard held != oldValue else { return }
            kitAnimate("transform", to: NSValue(caTransform3D: held && !Motion.reduced ? CATransform3DMakeScale(1.12, 1.12, 1) : CATransform3DIdentity),
                       curve: Motion.kitQuick, key: "held")
        }
    }

    init() {
        super.init(opacity: 0.35)
        fill.backgroundColor = NSColor.white.cgColor
        ring.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
        shape(CGSize(width: 7, height: 24), radius: 3.5, border: 0.5, shadow: 2, curve: .none)
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func move(to x: CGFloat, midY: CGFloat, scale: CGFloat, curve: KitCurve) {
        let origin = CGPoint(x: LookInk.snap(x - 3.5, scale), y: LookInk.snap(midY - 12, scale))
        kitAnimate("position", to: NSValue(point: CGPoint(x: origin.x + 3.5, y: origin.y + 12)), curve: curve)
    }
}

class LookSliderBase: NSView {
    let handle = LookHandle()
    var ended: () -> Void = {}
    var label: String { "" }
    var spokenValue: String { "" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var wantsUpdateLayer: Bool { true }

    var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    override func accessibilityLabel() -> String? { label }
    override func accessibilityValue() -> Any? { spokenValue }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    func local(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override var acceptsFirstResponder: Bool { KitFocus.takes(true) }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: _ = accessibilityPerformDecrement()
        case 124, 126: _ = accessibilityPerformIncrement()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        handle.held = true
        drag(local(event))
    }

    override func mouseDragged(with event: NSEvent) { drag(local(event)) }

    override func mouseUp(with event: NSEvent) {
        handle.held = false
        ended()
    }

    func drag(_ point: CGPoint) {}
}

final class LookTrackSlider: LookSliderBase {
    var moved: (Double) -> Void = { _ in }
    var name: String
    private let notch: Double?
    private let spoken: (Double) -> String
    private let track = StillGradient()
    private let notchLayer = StillLayer()
    private var value: Double = 0
    private var colours: [NSColor] = []

    init(label: String, notch: Double? = nil, spoken: @escaping (Double) -> String = { "\(Int($0 * 100))%" }) {
        name = label
        self.notch = notch
        self.spoken = spoken
        super.init(frame: .zero)
        track.startPoint = CGPoint(x: 0, y: 0.5)
        track.endPoint = CGPoint(x: 1, y: 0.5)
        track.borderWidth = 0.5
        layer?.addSublayer(track)
        if notch != nil { layer?.addSublayer(notchLayer) }
        layer?.addSublayer(handle)
    }

    override var label: String { name }
    override var spokenValue: String { spoken(value) }

    func show(value: Double, track colours: [NSColor], locations: [Double]?, curve: KitCurve) {
        self.value = value
        self.colours = colours
        track.locations = locations?.map { NSNumber(value: $0) }
        needsDisplay = true
        place(curve: curve)
    }

    override func updateLayer() {
        let dark = kitDark
        track.colors = colours.map { $0.kitResolved(dark: dark).cgColor }
        track.borderColor = LookInk.primary(0.12).kitResolved(dark: dark).cgColor
        notchLayer.backgroundColor = LookInk.primary(0.35).kitResolved(dark: dark).cgColor
    }

    override func layout() {
        super.layout()
        track.frame = CGRect(x: 0, y: (bounds.height - 8) / 2, width: bounds.width, height: 8)
        track.cornerRadius = 4
        if let notch {
            let x = 4 + (bounds.width - 8) * notch
            notchLayer.frame = CGRect(x: LookInk.snap(x - 0.75, scale), y: LookInk.snap(bounds.height / 2 - 7, scale), width: 1.5, height: 14)
            notchLayer.cornerRadius = 0.75
        }
        place(curve: .none)
    }

    private func place(curve: KitCurve) {
        handle.move(to: 4 + (bounds.width - 8) * value, midY: bounds.height / 2, scale: scale, curve: curve)
    }

    override func drag(_ point: CGPoint) {
        moved(min(1, max(0, (point.x - 4) / max(1, bounds.width - 8))))
    }

    override func accessibilityPerformIncrement() -> Bool {
        moved(min(1, value + 0.1))
        ended()
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        moved(max(0, value - 0.1))
        ended()
        return true
    }
}

final class LookClearSlider: LookSliderBase {
    var moved: (Double, Bool) -> Void = { _, _ in }
    private static let bead: CGFloat = 22
    private let wave = StillShape()
    private let rest = StillShape()
    private let glassBead = KitGlass(tint: Palette.NS.glassTint, interactive: true)
    private let beadEdge = KitBox(fill: nil, corners: .capsule)
    private var value: Double = 0
    private var glass = false
    private var builtFor: CGFloat = -1
    private var waveLengths: [CGFloat] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        for line in [wave, rest] {
            line.fillColor = nil
            line.lineWidth = 1.6
            line.lineCap = .round
            layer?.addSublayer(line)
        }
        glassBead.capsule = true
        addSubview(glassBead)
        addSubview(beadEdge)
        layer?.addSublayer(handle)
        handle.zPosition = 1
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return glassBead.kitCatch(at: convert(point, from: superview), in: self) ?? hit
    }

    override var label: String { "Transparency" }
    override var spokenValue: String { glass ? "Glass" : "\(Int(value * 100))%" }

    private var room: CGFloat { bounds.width - Self.bead - 10 }

    func show(value: Double, glass: Bool, curve: KitCurve) {
        let flipped = glass != self.glass
        self.value = value
        self.glass = glass
        beadEdge.layer?.kitTransition(flipped ? curve : .none)
        beadEdge.stroke = LookInk.primary(glass ? 0.85 : 0.3)
        beadEdge.strokeWidth = glass ? 2 : nil
        handle.kitAnimate("opacity", to: glass ? 0 : 1, curve: flipped ? curve : .none)
        place(curve: flipped ? curve : .none)
    }

    override func updateLayer() {
        let dark = kitDark
        wave.strokeColor = LookInk.primary(0.5).kitResolved(dark: dark).cgColor
        rest.strokeColor = LookInk.primary(0.22).kitResolved(dark: dark).cgColor
    }

    override func layout() {
        super.layout()
        let room = self.room
        if builtFor != bounds.width {
            builtFor = bounds.width
            let path = CGMutablePath()
            let midY = bounds.height / 2
            path.move(to: CGPoint(x: 0, y: midY))
            var lengths: [CGFloat] = [0]
            var last = CGPoint(x: 0, y: midY)
            var x: CGFloat = 0
            while x < room {
                x = min(room, x + 1)
                let swell = sin(x / max(1, bounds.width) * .pi) * 3 + 1
                let point = CGPoint(x: x, y: midY + sin(x / 5.5) * swell)
                path.addLine(to: point)
                lengths.append(lengths[lengths.count - 1] + hypot(point.x - last.x, point.y - last.y))
                last = point
            }
            waveLengths = lengths
            wave.path = path
            let line = CGMutablePath()
            line.move(to: CGPoint(x: 0, y: midY))
            line.addLine(to: CGPoint(x: room, y: midY))
            rest.path = line
        }
        wave.frame = bounds
        rest.frame = bounds
        let bead = NSRect(x: bounds.width - Self.bead, y: (bounds.height - Self.bead) / 2, width: Self.bead, height: Self.bead)
        glassBead.frame = bead
        beadEdge.frame = bead
        place(curve: .none)
    }

    private func reachFraction(_ reach: CGFloat) -> CGFloat {
        guard let total = waveLengths.last, total > 0, reach > 0 else { return 0 }
        let whole = Int(reach)
        guard whole + 1 < waveLengths.count else { return 1 }
        let length = waveLengths[whole] + (waveLengths[whole + 1] - waveLengths[whole]) * (reach - CGFloat(whole))
        return min(1, length / total)
    }

    private func place(curve: KitCurve) {
        let room = self.room
        let handleX = glass ? bounds.width - Self.bead / 2 : room * value
        let reach = min(handleX, room)
        wave.kitAnimate("strokeEnd", to: reachFraction(reach), curve: curve)
        rest.kitAnimate("strokeStart", to: room > 0 ? reach / room : 0, curve: curve)
        handle.move(to: handleX, midY: bounds.height / 2, scale: scale, curve: curve)
    }

    override func drag(_ point: CGPoint) {
        if point.x > room + 6 {
            if !glass {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                moved(value, true)
            }
        } else {
            moved(min(1, max(0, point.x / room)), false)
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        if value >= 1 { moved(1, true) } else { moved(min(1, value + 0.1), false) }
        ended()
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        moved(glass ? 1 : max(0, value - 0.1), false)
        ended()
        return true
    }
}

final class LookGrainSlider: LookSliderBase {
    var moved: (Double) -> Void = { _ in }
    private let specks = LookSpecks()
    private var value: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(specks)
        layer?.addSublayer(handle)
        handle.zPosition = 1
    }

    override var label: String { "Grain" }
    override var spokenValue: String { "\(Int(value * 100))%" }

    func show(value: Double) {
        self.value = value
        specks.value = value
        place()
    }

    override func layout() {
        super.layout()
        specks.frame = bounds
        place()
    }

    private func place() {
        handle.move(to: bounds.width * value, midY: bounds.height / 2, scale: scale, curve: .none)
    }

    override func drag(_ point: CGPoint) {
        moved(min(1, max(0, point.x / max(1, bounds.width))))
    }

    override func accessibilityPerformIncrement() -> Bool {
        moved(min(1, value + 0.1))
        ended()
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        moved(max(0, value - 0.1))
        ended()
        return true
    }
}

final class LookSpecks: NSView {
    var value: Double = 0 { didSet { if value != oldValue { needsDisplay = true } } }

    private static let specks: [(x: CGFloat, y: CGFloat, side: CGFloat)] = {
        var seed: UInt64 = 0x5EED
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) & 0xFFFF) / 0xFFFF
        }
        return (0..<260).map { _ in
            let x = sqrt(next())
            return (x, next(), 0.8 + next() * 0.9)
        }
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = kitDark
        let lit = LookInk.primary(0.8).kitResolved(dark: dark).cgColor
        let dim = LookInk.primary(0.3).kitResolved(dark: dark).cgColor
        for speck in Self.specks {
            let rect = CGRect(x: speck.x * bounds.width, y: 3 + speck.y * (bounds.height - 6), width: speck.side, height: speck.side)
            context.setFillColor(speck.x <= value ? lit : dim)
            context.fillEllipse(in: rect)
        }
    }
}
