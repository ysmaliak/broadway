import AppKit
import Combine

struct SpaceLook: Codable, Equatable {
    var colour: String = "gray"
    var custom: String?
    var colours: [String]?
    var intensity: Double?
    var transparency: Double = 0
    var grain: Double = 0
    var glass: Bool = false
    var mode: Mode?
    var fixed: Side?
    var darkTone: Tone?
    var lightTone: Tone?

    enum Mode: String, Codable { case one, both }

    enum Side: String, Codable {
        case dark, light

        init(dark: Bool) { self = dark ? .dark : .light }
        var isDark: Bool { self == .dark }
    }

    static let calm = 0.15
    static let bold = 0.8
    static let real = 2.0
    static let knee = 0.75

    static func position(of intensity: Double) -> Double {
        intensity <= 1 ? max(0, intensity) * knee : knee + (min(real, intensity) - 1) / (real - 1) * (1 - knee)
    }

    static func intensity(at position: Double) -> Double {
        let p = min(1, max(0, position))
        return p <= knee ? p / knee : 1 + (p - knee) / (1 - knee) * (real - 1)
    }

    static func spoken(_ position: Double) -> String {
        position > knee ? "Vivid \(Int(((position - knee) / (1 - knee) * 100).rounded()))%" : "\(Int((intensity(at: position) * 100).rounded()))%"
    }

    struct Preset {
        let id: String
        let name: String
        let hue: Double
        let swatch: Double
        let dark: (l: Double, c: Double)
        let light: (l: Double, c: Double)

        var hex: String { Oklch(l: swatch == 0 ? (id == "graphite" ? 0.45 : 0.9) : 0.74, c: swatch, h: hue).hex }
    }

    struct Theme {
        let id: String
        let name: String
        let colours: [String]
        let intensity: Double

        var look: SpaceLook { SpaceLook(colours: colours, intensity: intensity) }
        var tone: Tone { Tone(colours: colours, intensity: intensity) }
    }

    struct Tone: Codable, Equatable, Hashable {
        var colour: String = "gray"
        var custom: String?
        var colours: [String]?
        var intensity: Double?

        init(colour: String = "gray", custom: String? = nil, colours: [String]? = nil, intensity: Double? = nil) {
            self.colour = colour
            self.custom = custom
            self.colours = colours
            self.intensity = intensity
        }

        init(colours: [String], intensity: Double) {
            colour = "custom"
            custom = colours.first
            self.colours = colours.count > 1 ? Array(colours.prefix(3)) : nil
            self.intensity = intensity
        }

        private enum Keys: String, CodingKey { case colour, custom, colours, intensity }

        init(from decoder: Decoder) throws {
            let saved = try decoder.container(keyedBy: Keys.self)
            colour = (try? saved.decodeIfPresent(String.self, forKey: .colour)) ?? "gray"
            custom = (try? saved.decodeIfPresent(String.self, forKey: .custom)) ?? nil
            colours = ((try? saved.decodeIfPresent([String].self, forKey: .colours)) ?? nil).flatMap { $0.count > 1 ? Array($0.prefix(3)) : nil }
            intensity = ((try? saved.decodeIfPresent(Double.self, forKey: .intensity)) ?? nil).map { min(SpaceLook.real, max(0, $0)) }
        }

        func encode(to encoder: Encoder) throws {
            var out = encoder.container(keyedBy: Keys.self)
            try out.encode(colour, forKey: .colour)
            try out.encodeIfPresent(custom, forKey: .custom)
            try out.encodeIfPresent(colours, forKey: .colours)
            try out.encodeIfPresent(intensity, forKey: .intensity)
        }

        var hex: String {
            if colour == "custom", let first = colours?.first ?? custom { return first }
            return SpaceLook.presets.first { $0.id == colour }?.hex ?? SpaceLook.presets[1].hex
        }

        var picked: [String] {
            if colour == "custom" { return colours ?? custom.map { [$0] } ?? [SpaceLook.presets[1].hex] }
            return [hex]
        }

        var preset: Preset? {
            colour == "custom" ? nil : SpaceLook.palette.first { $0.id == colour } ?? SpaceLook.palette[1]
        }

        var strength: Double { intensity ?? SpaceLook.calm }
        var vivid: Double { colour == "custom" ? min(1, max(0, strength - 1)) : 0 }

        func ground(dark: Bool) -> Paint.Ground {
            if let preset {
                let stop = dark ? Oklch(l: preset.dark.l, c: preset.dark.c, h: preset.hue) : Oklch(l: preset.light.l, c: preset.light.c, h: preset.hue)
                return Paint.Ground(stops: [stop], lightInk: Paint.lightInkLean(stop, dark: dark) > 0)
            }
            return Paint.ground(picked, intensity: strength, dark: dark)
        }

        var constant: Bool { ground(dark: true) == ground(dark: false) }

    }

    static let palette: [Preset] = [
        Preset(id: "graphite", name: "Graphite", hue: 0, swatch: 0, dark: (0.255, 0), light: (0.865, 0)),
        Preset(id: "gray", name: "Gray", hue: 0, swatch: 0, dark: (0.30, 0), light: (0.945, 0)),
        Preset(id: "paper", name: "Paper", hue: 75, swatch: 0.06, dark: (0.30, 0.016), light: (0.94, 0.02)),
        Preset(id: "coral", name: "Coral", hue: 33, swatch: 0.13, dark: (0.30, 0.045), light: (0.915, 0.04)),
        Preset(id: "peach", name: "Peach", hue: 62, swatch: 0.11, dark: (0.305, 0.04), light: (0.925, 0.045)),
        Preset(id: "sage", name: "Sage", hue: 145, swatch: 0.09, dark: (0.295, 0.035), light: (0.915, 0.035)),
        Preset(id: "sky", name: "Sky", hue: 245, swatch: 0.10, dark: (0.295, 0.04), light: (0.915, 0.035)),
        Preset(id: "lavender", name: "Lavender", hue: 295, swatch: 0.11, dark: (0.295, 0.045), light: (0.915, 0.04)),
        Preset(id: "rose", name: "Rose", hue: 355, swatch: 0.11, dark: (0.295, 0.045), light: (0.915, 0.04)),
    ]

    static let themes: [Theme] = [
        Theme(id: "cobalt", name: "Cobalt", colours: ["3139FB"], intensity: 1),
        Theme(id: "ember", name: "Ember", colours: ["FB3A4D"], intensity: 1),
        Theme(id: "midnight", name: "Midnight", colours: ["000354", "2404AA"], intensity: 1),
        Theme(id: "ink", name: "Ink", colours: ["000000"], intensity: 1),
        Theme(id: "sunset", name: "Sunset", colours: ["FF89B3", "FF8A1F"], intensity: 0.75),
        Theme(id: "lagoon", name: "Lagoon", colours: ["0F9D94", "8CACFF"], intensity: 0.8),
        Theme(id: "lilac", name: "Lilac", colours: ["F0B4FF", "8CACFF"], intensity: 0.75),
        Theme(id: "citrus", name: "Citrus", colours: ["E8FF1A", "8BE33A"], intensity: 0.6),
        Theme(id: "aurora", name: "Aurora", colours: ["8BE33A", "7CC4F2", "7B3FE4"], intensity: 0.7),
        Theme(id: "onyx", name: "Onyx", colours: ["000000"], intensity: real),
        Theme(id: "abyss", name: "Abyss", colours: ["000354"], intensity: real),
        Theme(id: "volt", name: "Volt", colours: [volt], intensity: real),
    ]

    static let volt = "p3:3029FF"

    static let presets: [(id: String, name: String, hex: String)] = palette.map { ($0.id, $0.name, $0.hex) }

    struct Swatch: Equatable {
        let id: String
        let name: String
        let tone: Tone
    }

    static let swatchIDs = ["gray", "peach", "sage", "sky", "lavender", "rose", "sunset", "lagoon", "cobalt", "ember", "midnight", "onyx"]

    static let swatches: [Swatch] = swatchIDs.compactMap { id in
        if let preset = palette.first(where: { $0.id == id }) { return Swatch(id: id, name: preset.name, tone: Tone(colour: id)) }
        if let theme = themes.first(where: { $0.id == id }) { return Swatch(id: id, name: theme.name, tone: theme.tone) }
        return nil
    }

    static func swatch(for tone: Tone) -> Swatch? { swatches.first { $0.tone == tone } }

    init(colours: [String], intensity: Double, transparency: Double = 0, grain: Double = 0, glass: Bool = false) {
        colour = "custom"
        custom = colours.first
        self.colours = colours.count > 1 ? Array(colours.prefix(3)) : nil
        self.intensity = intensity
        self.transparency = transparency
        self.grain = grain
        self.glass = glass
    }

    init(tone: Tone, transparency: Double = 0, grain: Double = 0, glass: Bool = false) {
        self.transparency = transparency
        self.grain = grain
        self.glass = glass
        self.tone = tone
    }

    var tone: Tone {
        get { Tone(colour: colour, custom: custom, colours: colours, intensity: intensity) }
        set {
            colour = newValue.colour
            custom = newValue.custom
            colours = newValue.colours
            intensity = newValue.intensity
        }
    }

    var hex: String { tone.hex }

    static let onyx = SpaceLook(colours: ["000000"], intensity: real)

    var picked: [String] { tone.picked }
    var preset: Preset? { tone.preset }
    var strength: Double { tone.strength }

    var oneColour: Bool { mode == .one || (mode == nil && darkTone == nil && lightTone == nil && tone.constant) }

    func shade(dark: Bool) -> Bool { mode == .one ? fixed?.isDark ?? dark : dark }

    func own(dark: Bool) -> Tone? {
        guard mode != .one else { return nil }
        return dark ? darkTone : lightTone
    }

    func side(dark: Bool) -> Tone { own(dark: dark) ?? own(dark: !dark) ?? tone }

    func follows(dark: Bool) -> Bool { own(dark: dark) == nil }

    func vivid(dark: Bool) -> Double { side(dark: dark).vivid }

    func ground(dark: Bool) -> Paint.Ground { side(dark: dark).ground(dark: shade(dark: dark)) }

    func inkLight(dark: Bool) -> Bool { ground(dark: dark).lightInk }
    func inkLift(dark: Bool) -> Double { ground(dark: dark).lift }

    var tint: NSColor {
        let dark = ground(dark: true).average.color
        let light = ground(dark: false).average.color
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    var pageTint: NSColor {
        func made(_ dark: Bool) -> NSColor {
            let shown = side(dark: dark)
            guard shown.colour == "custom" else { return ground(dark: dark).average.color }
            return Tone(colours: shown.picked, intensity: min(shown.strength, Self.calm)).ground(dark: shade(dark: dark)).average.color
        }
        let dark = made(true)
        let light = made(false)
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    mutating func paint(_ next: Tone, dark: Bool) {
        if oneColour {
            mode = .one
            fixed = fixed ?? Side(dark: dark)
            tone = next
            darkTone = nil
            lightTone = nil
            return
        }
        mode = .both
        if dark { darkTone = next } else { lightTone = next }
        tone = next
    }

    mutating func follow(dark: Bool) {
        guard mode == .both else { return }
        if dark { darkTone = nil } else { lightTone = nil }
        if let left = darkTone ?? lightTone { tone = left }
    }

    mutating func choose(oneColour: Bool, dark: Bool) {
        guard oneColour != self.oneColour else { return }
        let shown = side(dark: dark)
        darkTone = nil
        lightTone = nil
        if oneColour {
            mode = .one
            fixed = Side(dark: shade(dark: dark))
            tone = shown
        } else {
            mode = .both
            fixed = nil
            tone = shown
        }
    }

    var tones: [Tone] { [tone] + [darkTone, lightTone].compactMap { $0 } }

    static func tint(_ preset: Preset) -> NSColor {
        let dark = Oklch(l: preset.dark.l, c: preset.dark.c, h: preset.hue).color
        let light = Oklch(l: preset.light.l, c: preset.light.c, h: preset.hue).color
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    static func tint(hex: String) -> NSColor {
        if let preset = palette.first(where: { $0.hex == hex }) { return tint(preset) }
        return SpaceLook(colour: "custom", custom: hex).tint
    }

    private enum Keys: String, CodingKey {
        case colour, custom, colours, intensity, transparency, grain, glass, v, mode, fixed, dark, light
    }

    init(colour: String = "gray", custom: String? = nil, transparency: Double = 0, grain: Double = 0, glass: Bool = false) {
        self.colour = colour
        self.custom = custom
        self.transparency = transparency
        self.grain = grain
        self.glass = glass
    }

    init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: Keys.self)
        colour = try saved.decodeIfPresent(String.self, forKey: .colour) ?? "gray"
        custom = try saved.decodeIfPresent(String.self, forKey: .custom)
        colours = try saved.decodeIfPresent([String].self, forKey: .colours).flatMap { $0.count > 1 ? Array($0.prefix(3)) : nil }
        intensity = try saved.decodeIfPresent(Double.self, forKey: .intensity).map { min(Self.real, max(0, $0)) }
        let version = try saved.decodeIfPresent(Int.self, forKey: .v) ?? 1
        let oldDefaults = version < 2
        transparency = try saved.decodeIfPresent(Double.self, forKey: .transparency) ?? (oldDefaults ? 0.3 : 0)
        grain = try saved.decodeIfPresent(Double.self, forKey: .grain) ?? (oldDefaults ? 0.2 : 0)
        glass = try saved.decodeIfPresent(Bool.self, forKey: .glass) ?? oldDefaults
        if oldDefaults, transparency == 0.3, grain == 0.2, glass {
            transparency = 0
            grain = 0
            glass = false
        }
        mode = (try? saved.decodeIfPresent(Mode.self, forKey: .mode)) ?? nil
        fixed = (try? saved.decodeIfPresent(Side.self, forKey: .fixed)) ?? nil
        darkTone = (try? saved.decodeIfPresent(Tone.self, forKey: .dark)) ?? nil
        lightTone = (try? saved.decodeIfPresent(Tone.self, forKey: .light)) ?? nil
        if version < Self.version, let renewed = Self.renewed(self) { self = renewed }
    }

    static let version = 4

    func encode(to encoder: Encoder) throws {
        var out = encoder.container(keyedBy: Keys.self)
        try out.encode(colour, forKey: .colour)
        try out.encodeIfPresent(custom, forKey: .custom)
        try out.encodeIfPresent(colours, forKey: .colours)
        try out.encodeIfPresent(intensity, forKey: .intensity)
        try out.encode(transparency, forKey: .transparency)
        try out.encode(grain, forKey: .grain)
        try out.encode(glass, forKey: .glass)
        try out.encode(Self.version, forKey: .v)
        try out.encodeIfPresent(mode, forKey: .mode)
        try out.encodeIfPresent(fixed, forKey: .fixed)
        try out.encodeIfPresent(darkTone, forKey: .dark)
        try out.encodeIfPresent(lightTone, forKey: .light)
    }

    static func == (a: SpaceLook, b: SpaceLook) -> Bool {
        a.colour == b.colour && a.custom == b.custom && a.colours == b.colours && a.intensity == b.intensity
            && a.transparency == b.transparency && a.grain == b.grain && a.glass == b.glass
            && a.mode == b.mode && a.fixed == b.fixed && a.darkTone == b.darkTone && a.lightTone == b.lightTone
    }
}

extension SpaceLook {
    var showsThrough: Bool { transparency > 0 || glass }

    struct Offer: Equatable {
        let id: String
        let name: String
        let look: SpaceLook
    }

    static let offers: [Offer] = [
        Offer(id: "noir", name: "Noir", look: SpaceLook(colours: ["000000"], intensity: real, grain: 0.3)),
        Offer(id: "gray", name: "Gray", look: SpaceLook()),
        Offer(id: "glass", name: "Glass", look: SpaceLook(colour: "gray", glass: true)),
        Offer(id: "dusk", name: "Dusk", look: SpaceLook(colours: ["2B1A7A", "D23770", "BF5600"], intensity: real, grain: 0.4)),
        Offer(id: "paper", name: "Paper", look: SpaceLook(colours: ["EFE6D2"], intensity: real, grain: 0.5)),
        Offer(id: "borealis", name: "Borealis", look: SpaceLook(colours: ["0B1D51", "00846F", "7B3FE4"], intensity: real, grain: 0.4)),
    ]

    static let retired: [(was: SpaceLook, id: String)] = [
        (SpaceLook(colours: ["000000"], intensity: 1, transparency: 0.12, grain: 0.45), "noir"),
        (SpaceLook(colours: ["2B1A7A", "F0508C", "FFB05C"], intensity: 1.4, grain: 0.4), "dusk"),
    ]

    static func renewed(_ look: SpaceLook) -> SpaceLook? {
        retired.first { $0.was == look }.flatMap { offered($0.id) }
    }

    static let offered = offers.map(\.id)

    static func offered(_ id: String) -> SpaceLook? {
        offers.first { $0.id == id }?.look
    }

    static func offeredID(of look: SpaceLook?) -> String {
        let look = look ?? SpaceLook()
        return offers.first { $0.look == look }?.id ?? "custom"
    }

    static func opening(for look: SpaceLook?) -> String {
        look == nil ? offered[0] : offeredID(of: look)
    }

    static func offeredName(_ id: String) -> String {
        offers.first { $0.id == id }?.name ?? id
    }

    static func named(_ id: String, over now: SpaceLook = SpaceLook()) -> SpaceLook? {
        if palette.contains(where: { $0.id == id }) {
            return SpaceLook(colour: id, transparency: now.transparency, grain: now.grain, glass: now.glass)
        }
        guard let theme = themes.first(where: { $0.id == id }) else { return nil }
        return SpaceLook(colours: theme.colours, intensity: theme.intensity, transparency: now.transparency, grain: now.grain, glass: now.glass)
    }
}

struct LookBlend: Equatable {
    var from: SpaceLook
    var to: SpaceLook?
    var share: CGFloat = 0

    func stops(dark: Bool) -> [NSColor] {
        let here = Self.three(from.ground(dark: dark))
        guard let to, share > 0 else { return here }
        let there = Self.three(to.ground(dark: dark))
        return zip(here, there).map { Self.mix($0, $1, share) }
    }

    func inkLight(dark: Bool) -> Bool {
        guard let to, share >= 0.5 else { return from.inkLight(dark: dark) }
        return to.inkLight(dark: dark)
    }

    func inkLift(dark: Bool) -> Double {
        guard let to, share >= 0.5 else { return from.inkLift(dark: dark) }
        return to.inkLift(dark: dark)
    }

    func groundStops(dark: Bool) -> [Oklch] {
        guard let to, share >= 0.5 else { return from.ground(dark: dark).stops }
        return to.ground(dark: dark).stops
    }

    var tint: NSColor {
        let blend = self
        return NSColor(name: nil) { appearance in
            let colours = blend.stops(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            return colours.dropFirst().reduce(colours[0]) { Self.mix($0, $1, 0.5) }
        }
    }

    static func three(_ ground: Paint.Ground) -> [NSColor] {
        let colours = ground.stops.map(\.color)
        switch colours.count {
        case 0: return Array(repeating: NSColor(white: 0.9, alpha: 1), count: 3)
        case 1: return Array(repeating: colours[0], count: 3)
        case 2: return [colours[0], mix(colours[0], colours[1], 0.5), colours[1]]
        default: return Array(colours.prefix(3))
        }
    }

    static func mix(_ a: NSColor, _ b: NSColor, _ share: CGFloat) -> NSColor {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return a }
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * share,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * share,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * share, alpha: 1)
    }

    private func mixed(_ value: (SpaceLook) -> Double) -> Double {
        guard let to else { return value(from) }
        return value(from) + (value(to) - value(from)) * Double(share)
    }

    var transparency: Double { mixed(\.transparency) }
    var grain: Double { mixed(\.grain) }
    var glass: Double { mixed { $0.glass ? 1 : 0 } }
    func vivid(dark: Bool) -> Double { mixed { $0.vivid(dark: dark) } }

    func shade(dark: Bool) -> Bool {
        guard let to, share >= 0.5 else { return from.shade(dark: dark) }
        return to.shade(dark: dark)
    }
}

final class SpaceGroundView: NSView {
    static let anchor = 0.6
    static let vividAnchor = 0.85

    var blend: LookBlend { didSet { if blend != oldValue { render() } } }
    var solid: Bool { didSet { if solid != oldValue { render() } } }
    var spansWindow = true { didSet { if spansWindow != oldValue { render() } } }
    var groundDark: Bool? { didSet { if groundDark != oldValue { render() } } }
    var staged = false { didSet { if staged != oldValue { render() } } }
    var glassCorner: CGFloat = 0 { didSet { if glassCorner != oldValue { render() } } }

    static var bare = false

    private var glass: NSGlassEffectView?
    private var blur: NSVisualEffectView?
    private let paint = GroundPaintView()
    private var grain: GrainView?

    init(blend: LookBlend, opaque solid: Bool = false) {
        self.blend = blend
        self.solid = solid
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(paint)
        setAccessibilityElement(false)
    }

    convenience init(look: SpaceLook, opaque solid: Bool = false) {
        self.init(blend: LookBlend(from: look), opaque: solid)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        render()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        render()
    }

    private var dark: Bool { groundDark ?? kitDark }

    static func shown(transparency: Double, glass: Double, vivid: Double, blurred: Bool) -> Double {
        let glassy = blurred ? glass : 0
        let anchor = Self.anchor + (Self.vividAnchor - Self.anchor) * vivid
        return max((blurred ? 1 - transparency : 1) * (1 - glassy), glassy * anchor)
    }

    func render() {
        let dark = dark
        let blurred = !solid && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let glassy = blurred ? blend.glass : 0
        let stops = blend.stops(dark: dark)
        let vivid = blend.vivid(dark: dark)
        let ground = NSAppearance(named: blend.shade(dark: dark) ? .darkAqua : .aqua)
        let material = vivid > 0 ? NSAppearance(named: blend.inkLight(dark: dark) ? .darkAqua : .aqua) : nil
        Still.set {
            if glassy > 0 {
                let made = glass ?? {
                    let view = NSGlassEffectView()
                    view.cornerRadius = 0
                    addSubview(view, positioned: .below, relativeTo: nil)
                    glass = view
                    return view
                }()
                let tint = material == nil ? blend.tint : stops.dropFirst().reduce(stops[0]) { LookBlend.mix($0, $1, 0.5) }
                let wanted = material ?? ground
                if made.appearance?.name != wanted?.name { made.appearance = wanted }
                if made.cornerRadius != glassCorner { made.cornerRadius = glassCorner }
                made.tintColor = tint.withAlphaComponent(0.65)
                made.frame = bounds
            } else if let glass {
                glass.removeFromSuperview()
                self.glass = nil
            }
            if blurred, !staged, !Self.bare, glassy < 1, blend.transparency > 0 || glassy > 0 {
                let made = blur ?? {
                    let view = NSVisualEffectView()
                    view.blendingMode = .behindWindow
                    view.material = .underWindowBackground
                    view.state = .active
                    addSubview(view, positioned: .below, relativeTo: paint)
                    blur = view
                    return view
                }()
                made.alphaValue = 1 - glassy
                let wanted = material ?? ground
                if made.appearance?.name != wanted?.name { made.appearance = wanted }
                made.frame = bounds
            } else if let blur {
                blur.removeFromSuperview()
                self.blur = nil
            }
            paint.frame = bounds
            paint.layer?.opacity = Swift.Float(Self.shown(transparency: blend.transparency, glass: blend.glass, vivid: vivid, blurred: blurred))
            paint.show(stops, canvas: spansWindow ? groundCanvas : nil)
            if blend.grain > 0 {
                let made = grain ?? {
                    let view = GrainView()
                    addSubview(view)
                    grain = view
                    return view
                }()
                made.frame = bounds
                made.layer?.opacity = Swift.Float(blend.grain * GrainView.strength)
            } else if let grain {
                grain.removeFromSuperview()
                self.grain = nil
            }
        }
    }
}

final class GroundPaintView: NSView {
    private let gradient = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(gradient)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ stops: [NSColor], canvas: (frame: CGRect, size: CGSize)?) {
        let flat = stops.dropFirst().allSatisfy { $0 == stops[0] }
        gradient.frame = bounds
        if flat || stops.isEmpty {
            layer?.backgroundColor = (stops.first ?? .gray).cgColor
            gradient.isHidden = true
            return
        }
        layer?.backgroundColor = nil
        gradient.isHidden = false
        gradient.colors = stops.map(\.cgColor)
        let side = max(1, bounds.width, bounds.height)
        gradient.frame = CGRect(x: 0, y: 0, width: side, height: side)
        let start: CGPoint
        let end: CGPoint
        if let canvas {
            start = CGPoint(x: -canvas.frame.minX, y: -canvas.frame.minY)
            end = CGPoint(x: canvas.size.width - canvas.frame.minX, y: canvas.size.height - canvas.frame.minY)
        } else {
            start = .zero
            end = CGPoint(x: bounds.width, y: bounds.height)
        }
        gradient.startPoint = CGPoint(x: start.x / side, y: start.y / side)
        gradient.endPoint = CGPoint(x: end.x / side, y: end.y / side)
    }
}

final class GrainView: NSView {
    static let strength = 0.16
    static let side: CGFloat = 64

    @MainActor static let tile: NSImage = {
        let side = 128
        var generator = GrainSeed()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32),
              let data = rep.bitmapData else { return NSImage() }
        for index in 0..<(side * side) {
            let value = Int.random(in: 0...255, using: &generator)
            let alpha = UInt8(min(255, abs(value - 128) * 2))
            let light: UInt8 = value > 128 ? alpha : 0
            data[index * 4] = light
            data[index * 4 + 1] = light
            data[index * 4 + 2] = light
            data[index * 4 + 3] = alpha
        }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }()

    private let across = CAReplicatorLayer()
    private let down = CAReplicatorLayer()
    private let piece = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        piece.contents = Self.tile.representations.compactMap { ($0 as? NSBitmapImageRep)?.cgImage }.first
        piece.contentsGravity = .resize
        piece.frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        across.addSublayer(piece)
        down.addSublayer(across)
        layer?.addSublayer(down)
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        down.frame = bounds
        across.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.side)
        across.instanceCount = max(1, Int(ceil(bounds.width / Self.side)))
        across.instanceTransform = CATransform3DMakeTranslation(Self.side, 0, 0)
        down.instanceCount = max(1, Int(ceil(bounds.height / Self.side)))
        down.instanceTransform = CATransform3DMakeTranslation(0, Self.side, 0)
        CATransaction.commit()
    }
}

@MainActor
protocol SpaceFollowing: AnyObject {
    func follow(_ motion: SpaceMotion)
}

final class LiveGroundView: NSView, SpaceFollowing {
    let browser: Browser
    let motion: SpaceMotion
    var solid: Bool { didSet { if solid != oldValue { needsLayout = true } } }
    var groundDark: Bool? { didSet { if groundDark != oldValue { needsLayout = true } } }

    private let base: SpaceGroundView
    private var coming: (ride: RideView, ground: SpaceGroundView)?
    private var blending: (here: SpaceLook, next: SpaceLook)?
    private lazy var reads = KitReads(now: true) { [weak self] in
        if KitChange.easing { self?.eases = true }
        self?.needsLayout = true
    }
    private var eases = false
    private var shown: (space: UUID, look: SpaceLook)?

    init(browser: Browser, motion: SpaceMotion, opaque solid: Bool = false) {
        self.browser = browser
        self.motion = motion
        self.solid = solid
        base = SpaceGroundView(look: browser.seenLook, opaque: solid)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(base)
        motion.followers.add(self)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func still(_ look: SpaceLook) -> Bool {
        let blend = LookBlend(from: look)
        let blurred = !solid && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        return blend.glass == 0 && (!blurred || blend.transparency == 0)
    }

    override func layout() {
        reads.track { layoutNow() }
    }

    private func layoutNow() {
        super.layout()
        browser.spaceNeighbour.watch()
        let here = browser.seenLook
        let next = browser.spaceNext.map { browser.spaces.indices.contains($0) ? browser.spaces[$0].look ?? SpaceLook() : SpaceLook() }
        base.frame = bounds
        base.solid = solid
        base.groundDark = groundDark
        if let next, !(still(here) && still(next)) {
            blending = (here, next)
            base.blend = LookBlend(from: here, to: next, share: motion.progress)
            drop()
            return
        }
        blending = nil
        let space = browser.spaceID
        if next == nil, eases, let shown, shown.space == space, shown.look != here, window != nil {
            base.layer?.kitTransition(Motion.kitSettle)
        }
        eases = false
        shown = (space, here)
        base.blend = LookBlend(from: here)
        guard let next else { return drop() }
        let made = coming ?? {
            let ground = SpaceGroundView(look: next, opaque: solid)
            let ride = RideView(content: ground, motion: motion)
            addSubview(ride)
            coming = (ride, ground)
            return (ride, ground)
        }()
        made.ground.blend = LookBlend(from: next)
        made.ground.solid = solid
        made.ground.groundDark = groundDark
        made.ride.frame = bounds
        made.ride.set(RideLook(here: browser.spaceSeen, span: 0, clip: .none, band: false, hits: false, fade: .in, seen: true))
    }

    private func drop() {
        coming?.ride.removeFromSuperview()
        coming = nil
    }

    func follow(_ motion: SpaceMotion) {
        guard let blending else { return }
        base.blend = LookBlend(from: blending.here, to: blending.next, share: motion.progress)
    }
}

enum Still {
    static func set(_ change: () -> Void) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }
}

struct GrainSeed: RandomNumberGenerator {
    var state: UInt64 = 0x6B5EED

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
