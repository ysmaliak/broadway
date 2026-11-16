import AppKit

struct PinTint: Hashable {
    enum Mark: Hashable { case asIs, darkGlyph, lightGlyph }
    enum Shape: Hashable { case glyph, solid, mixed }
    enum Dress: Hashable { case plain, ink, edge, chip }

    static let chipInset: CGFloat = 0.125
    static let cornerRatio: CGFloat = 0.22
    static let solidCover: CGFloat = 0.6
    static let tileCover: CGFloat = 0.86
    static let flatShare: CGFloat = 0.94

    static func plate(_ mark: Mark, dark: Bool) -> NSColor? {
        switch mark {
        case .darkGlyph where dark: NSColor(white: 1, alpha: 0.6)
        case .lightGlyph where !dark: NSColor(white: 0, alpha: 0.55)
        default: nil
        }
    }

    static func edge(dark: Bool) -> NSColor {
        dark ? NSColor(white: 1, alpha: 0.3) : NSColor(white: 0, alpha: 0.18)
    }

    func dress(dark: Bool) -> Dress {
        switch mark {
        case .darkGlyph where dark, .lightGlyph where !dark:
            switch shape {
            case .glyph: .ink
            case .solid: .edge
            case .mixed: .chip
            }
        default: .plain
        }
    }

    func chip(dark: Bool) -> NSColor? {
        guard dress(dark: dark) == .chip else { return nil }
        return dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.78)
    }

    func backing(dark: Bool) -> NSColor? {
        switch dress(dark: dark) {
        case .ink, .chip: PinTint.plate(mark, dark: dark)
        case .plain, .edge: nil
        }
    }

    struct Hue: Hashable {
        let hue: CGFloat
        let saturation: CGFloat
    }

    let hue: CGFloat?
    let saturation: CGFloat
    let mark: Mark
    var others: [Hue] = []
    var shape: Shape = .glyph
    var seed: UInt64 = 0

    var hues: [Hue] { (hue.map { [Hue(hue: $0, saturation: saturation)] } ?? []) + others }

    func seeded(_ key: String) -> PinTint {
        guard !key.isEmpty else { return self }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        var made = self
        made.seed = hash | 1
        return made
    }

    static let neutral = PinTint(hue: nil, saturation: 0, mark: .asIs)
    static let mostHues = 3

    static let side = 16
    static let leastCoverage: CGFloat = 0.08
    static let leastSaturation: CGFloat = 0.28
    static let leastBrightness: CGFloat = 0.22

    struct Pixel {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    static func derive(_ pixels: [Pixel]) -> PinTint {
        let opaque = pixels.filter { $0.alpha > 0.5 }
        guard !opaque.isEmpty else { return .neutral }
        let bins = 24
        var weight = [CGFloat](repeating: 0, count: bins)
        var x = [CGFloat](repeating: 0, count: bins)
        var y = [CGFloat](repeating: 0, count: bins)
        var sat = [CGFloat](repeating: 0, count: bins)
        var count = [Int](repeating: 0, count: bins)
        var light: CGFloat = 0
        for pixel in opaque {
            let (h, s, b) = hsb(pixel)
            light += 0.2126 * pixel.red + 0.7152 * pixel.green + 0.0722 * pixel.blue
            guard s >= leastSaturation, b >= leastBrightness else { continue }
            let bin = min(bins - 1, Int(h * CGFloat(bins)))
            let w = s * pixel.alpha
            weight[bin] += w
            x[bin] += cos(h * 2 * .pi) * w
            y[bin] += sin(h * 2 * .pi) * w
            sat[bin] += s * w
            count[bin] += 1
        }
        let mean = light / CGFloat(opaque.count)
        let glyph: Mark = mean < 0.28 ? .darkGlyph : mean > 0.86 ? .lightGlyph : .asIs
        let shape: Shape = {
            guard glyph != .asIs else { return .glyph }
            let cover = CGFloat(opaque.count) / CGFloat(pixels.count)
            let alike = opaque.filter { pixel in
                let level = 0.2126 * pixel.red + 0.7152 * pixel.green + 0.0722 * pixel.blue
                return glyph == .darkGlyph ? level < 0.4 : level > 0.75
            }
            let flat = CGFloat(alike.count) / CGFloat(opaque.count) >= flatShare
            if cover >= tileCover { return .solid }
            if flat { return .glyph }
            return cover >= solidCover ? .solid : .mixed
        }()
        func around(_ bin: Int) -> [Int] { [(bin + bins - 1) % bins, bin, (bin + 1) % bins] }
        guard let peak = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[peak] > 0 else {
            return PinTint(hue: nil, saturation: 0, mark: glyph, shape: shape)
        }
        func covered(_ bin: Int) -> CGFloat {
            CGFloat(around(bin).map { count[$0] }.reduce(0, +)) / CGFloat(opaque.count)
        }
        func found(_ bin: Int) -> Hue {
            let near = around(bin)
            let total = near.map { weight[$0] }.reduce(0, +)
            let angle = atan2(near.map { y[$0] }.reduce(0, +), near.map { x[$0] }.reduce(0, +))
            return Hue(hue: (angle / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1),
                       saturation: near.map { sat[$0] }.reduce(0, +) / total)
        }
        guard covered(peak) >= leastCoverage else { return PinTint(hue: nil, saturation: 0, mark: glyph, shape: shape) }
        var taken = [peak]
        for bin in weight.indices.sorted(by: { weight[$0] > weight[$1] }) where taken.count < mostHues {
            guard weight[bin] > 0, covered(bin) >= leastCoverage,
                  taken.allSatisfy({ min(abs($0 - bin), bins - abs($0 - bin)) >= 3 }) else { continue }
            taken.append(bin)
        }
        let first = found(peak)
        return PinTint(hue: first.hue, saturation: first.saturation, mark: .asIs, others: taken.dropFirst().map(found))
    }

    static func hsb(_ pixel: Pixel) -> (CGFloat, CGFloat, CGFloat) {
        let high = max(pixel.red, pixel.green, pixel.blue)
        let low = min(pixel.red, pixel.green, pixel.blue)
        let range = high - low
        let s = high == 0 ? 0 : range / high
        guard range > 0 else { return (0, s, high) }
        var h: CGFloat
        if high == pixel.red { h = (pixel.green - pixel.blue) / range }
        else if high == pixel.green { h = 2 + (pixel.blue - pixel.red) / range }
        else { h = 4 + (pixel.red - pixel.green) / range }
        h /= 6
        if h < 0 { h += 1 }
        return (h, s, high)
    }

    static func pixels(of image: NSImage) -> [Pixel] {
        let side = PinTint.side
        var rect = NSRect(x: 0, y: 0, width: side, height: side)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return [] }
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }
        return stride(from: 0, to: bytes.count, by: 4).map { index in
            let alpha = CGFloat(bytes[index + 3]) / 255
            guard alpha > 0 else { return Pixel(red: 0, green: 0, blue: 0, alpha: 0) }
            return Pixel(red: min(1, CGFloat(bytes[index]) / 255 / alpha),
                         green: min(1, CGFloat(bytes[index + 1]) / 255 / alpha),
                         blue: min(1, CGFloat(bytes[index + 2]) / 255 / alpha), alpha: alpha)
        }
    }

    @MainActor private static let kept = NSMapTable<NSImage, Box>.weakToStrongObjects()
    private final class Box { let tint: PinTint; init(_ tint: PinTint) { self.tint = tint } }

    @MainActor static func of(_ image: NSImage?) -> PinTint {
        guard let image else { return .neutral }
        if image.isTemplate { return .neutral }
        if let known = kept.object(forKey: image) { return known.tint }
        let tint = derive(pixels(of: image))
        kept.setObject(Box(tint), forKey: image)
        return tint
    }
}

struct PinLook {
    enum State { case resting, hovered, picked, live }
    enum Part { case fill, edge, rim }
    enum Band { case outer, inner }

    static let ring: CGFloat = 3

    static func gain(dark: Bool, part: Part, state: State) -> Double {
        switch (dark, part, state) {
        case (_, _, .resting): 1
        case (true, .fill, .hovered): 1.37
        case (true, .fill, .picked): 1.6
        case (true, .fill, .live): 5.4
        case (true, .edge, .hovered): 1.4
        case (true, .edge, .picked): 1.8
        case (true, .edge, .live): 5.9
        case (false, .fill, .hovered): 1.37
        case (false, .fill, .picked): 1.6
        case (false, .fill, .live): 3.7
        case (false, .edge, .hovered): 1.4
        case (false, .edge, .picked): 1.8
        case (false, .edge, .live): 6
        case (true, .rim, .hovered): 1.3
        case (true, .rim, .picked): 1.4
        case (true, .rim, .live): 1.4
        case (false, .rim, .hovered): 1.5
        case (false, .rim, .picked): 1.5
        case (false, .rim, .live): 1.5
        }
    }

    static func tone(_ greys: KitGreys, part: Part, state: State, dark: Bool) -> KitTone {
        let base = switch part {
        case .fill: greys.raised
        case .edge: state == .picked ? greys.cardEdge : greys.raisedEdge
        case .rim: greys.raisedRim
        }
        return base.opacity(gain(dark: dark, part: part, state: state))
    }

    static func colour(_ greys: KitGreys, _ ink: KitInk, part: Part, state: State, dark: Bool) -> NSColor {
        tone(greys, part: part, state: state, dark: dark).resolved(ink, dark: dark)
    }

    static func foot(_ greys: KitGreys, _ ink: KitInk, state: State, dark: Bool) -> NSColor {
        greys.raisedFoot.opacity(gain(dark: dark, part: .fill, state: state)).resolved(ink, dark: dark)
    }

    static func rim(_ greys: KitGreys, _ ink: KitInk, state: State = .resting, dark: Bool) -> NSColor {
        tone(greys, part: .rim, state: state, dark: dark).resolved(ink, dark: dark)
    }

    static func ramp(_ greys: KitGreys, _ ink: KitInk, state: State = .resting, dark: Bool) -> NSColor {
        greys.raisedRamp.opacity(gain(dark: dark, part: .edge, state: state)).resolved(ink, dark: dark)
    }

    static func hued(_ state: State) -> Bool { state == .live }

    static func over(_ alpha: CGFloat, resting: CGFloat) -> CGFloat {
        guard resting < 1 else { return 0 }
        return max(0, 1 - (1 - alpha) / (1 - resting))
    }

    static func neutralRing(dark: Bool, band: Band) -> CGFloat {
        switch (dark, band) {
        case (true, .outer): 0.62
        case (true, .inner): 0.4
        case (false, .outer): 0.36
        case (false, .inner): 0.22
        }
    }

    static func ringNS(_ hue: CGFloat, _ saturation: CGFloat, _ band: Band, dark: Bool) -> NSColor {
        let strong = min(1, max(0.7, saturation))
        return switch (dark, band) {
        case (true, .outer): NSColor(hue: hue, saturation: strong * 0.5, brightness: 0.62, alpha: 1)
        case (true, .inner): NSColor(hue: hue, saturation: strong * 0.92, brightness: 0.54, alpha: 1)
        case (false, .outer): NSColor(hue: hue, saturation: strong * 0.7, brightness: 0.86, alpha: 1)
        case (false, .inner): NSColor(hue: hue, saturation: strong, brightness: 0.74, alpha: 1)
        }
    }

    private struct MeshKey: Hashable {
        let hues: [PinTint.Hue]
        let seed: UInt64
        let dark: Bool
    }

    static let meshesKept = 64
    @MainActor private static var meshes: [MeshKey: CGImage] = [:]
    @MainActor private static var meshOrder: [MeshKey] = []

    @MainActor static var meshCount: Int { meshes.count }

    @MainActor static func mesh(_ tint: PinTint, dark: Bool) -> CGImage? {
        let key = MeshKey(hues: tint.hues, seed: tint.seed, dark: dark)
        if let known = meshes[key] {
            if meshOrder.last != key, let at = meshOrder.firstIndex(of: key) { meshOrder.append(meshOrder.remove(at: at)) }
            return known
        }
        let draw = PinMesh.draw(tint, dark: dark)
        let image = KitMesh.image(width: PinMesh.width, height: PinMesh.height, points: draw.points, colours: draw.tones.map(\.colour),
                                  size: PinMesh.size, scale: 2)
        var rect = NSRect(origin: .zero, size: image.size)
        guard let made = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        if meshes.count >= meshesKept, !meshOrder.isEmpty { meshes[meshOrder.removeFirst()] = nil }
        meshes[key] = made
        meshOrder.append(key)
        return made
    }
}

enum PinMesh {
    static let width = 4
    static let height = 4
    static let size = CGSize(width: 64, height: 48)
    static let hueReach: CGFloat = 0.025
    static let shift: Swift.Float = 0.24 / Swift.Float(width - 1)
    static let attempts = 160
    static let inner: [Int] = {
        let rows = (height / 4)...(height - 1 - height / 4)
        let columns = (width / 4)...(width - 1 - width / 4)
        return rows.flatMap { row in columns.map { row * width + $0 } }
    }()
    static let fewestHighlights = max(2, rim.count / 6)
    static let fewestOpenings = max(3, rim.count / 4)
    static let lightFloor: CGFloat = 0.92

    enum Level: Hashable { case lift, middle, rest }

    struct Tone: Hashable {
        let hue: CGFloat
        let saturation: CGFloat
        let brightness: CGFloat
        let alpha: CGFloat
        let level: Level
        let family: Int

        var colour: NSColor {
            NSColor(colorSpace: .sRGB, hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
        }
    }

    struct Draw: Equatable {
        let points: [SIMD2<Swift.Float>]
        let tones: [Tone]
    }

    struct Dice {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }

        mutating func spread(_ reach: Swift.Float) -> Swift.Float { Swift.Float(unit() * 2 - 1) * reach }

        mutating func below(_ count: Int) -> Int { Int(next() % UInt64(max(1, count))) }
    }

    struct Rules {
        let step: Double
        let calm: Double
        let mean: ClosedRange<Double>
        let ground: NSColor
    }

    static func rules(dark: Bool) -> Rules {
        dark ? Rules(step: 0.22, calm: 0.08, mean: 0.36...0.54, ground: NSColor(white: 0.12, alpha: 1))
             : Rules(step: 0.1, calm: 0.05, mean: 0.86...0.95, ground: NSColor(white: 0.97, alpha: 1))
    }

    static func turn(_ hue: CGFloat, by amount: CGFloat) -> CGFloat {
        (hue + amount + 1).truncatingRemainder(dividingBy: 1)
    }

    static func hueGap(_ one: CGFloat, _ other: CGFloat) -> CGFloat {
        let gap = abs(one - other).truncatingRemainder(dividingBy: 1)
        return min(gap, 1 - gap)
    }

    private static func alpha(_ level: Level, dark: Bool) -> CGFloat {
        guard dark else { return 0.95 }
        return switch level {
        case .lift: 0.92
        case .middle: 0.86
        case .rest: 0.8
        }
    }

    private static func tone(_ hue: CGFloat, _ saturation: CGFloat, _ target: Double, _ level: Level, family: Int, dark: Bool) -> Tone {
        var s = min(1, max(0, saturation))
        func seen(_ s: CGFloat, _ b: CGFloat) -> Double {
            KitMesh.lab(NSColor(colorSpace: .sRGB, hue: hue, saturation: s, brightness: b, alpha: 1)).l
        }
        func search(_ low: CGFloat, _ high: CGFloat, darker: Bool, _ probe: (CGFloat) -> Double) -> CGFloat {
            var low = low, high = high
            for _ in 0..<18 {
                let middle = (low + high) / 2
                if (probe(middle) < target) == darker { high = middle } else { low = middle }
            }
            return (low + high) / 2
        }
        var b: CGFloat = 1
        if !dark, seen(s, 1) > target {
            b = max(s > 0 ? lightFloor : 0, search(0, 1, darker: false) { seen(s, $0) })
        } else {
            while s > 0.02, seen(s, 1) < target { s *= 0.9 }
            b = search(0, 1, darker: false) { seen(s, $0) }
        }
        return Tone(hue: hue, saturation: s, brightness: b, alpha: alpha(level, dark: dark), level: level, family: family)
    }

    static func palette(_ tint: PinTint, dark: Bool) -> [Tone] {
        let hues = tint.hues
        guard !hues.isEmpty else {
            let greys: [(Double, Level)] = dark
                ? [(0.72, .lift), (0.56, .middle), (0.42, .rest), (0.36, .rest)]
                : [(0.84, .lift), (0.89, .middle), (0.94, .rest), (0.98, .rest)]
            return greys.map { tone(0, 0, $0.0, $0.1, family: 0, dark: dark) }
        }
        var tones: [Tone] = []
        for (family, hue) in hues.enumerated() {
            let s = min(0.9, max(0.5, hue.saturation))
            let h = hue.hue
            tones += dark
                ? [tone(h, s * 0.85, 0.7, .lift, family: family, dark: dark), tone(h, s, 0.54, .middle, family: family, dark: dark),
                   tone(h, s * 0.9, 0.4, .rest, family: family, dark: dark)]
                : [tone(h, s * 0.6, 0.83, .lift, family: family, dark: dark), tone(h, s * 0.38, 0.89, .middle, family: family, dark: dark),
                   tone(h, s * 0.16, 0.96, .rest, family: family, dark: dark)]
        }
        if hues.count < PinTint.mostHues {
            for (family, hue) in hues.enumerated() {
                let s = min(0.9, max(0.5, hue.saturation))
                let up = turn(hue.hue, by: hueReach), down = turn(hue.hue, by: -hueReach)
                tones += dark
                    ? [tone(up, s * 0.6, 0.64, .lift, family: family, dark: dark), tone(down, s, 0.35, .rest, family: family, dark: dark)]
                    : [tone(up, s * 0.85, 0.86, .lift, family: family, dark: dark), tone(down, s * 0.28, 0.94, .rest, family: family, dark: dark)]
            }
        }
        return tones
    }

    static func lightness(_ tone: Tone, dark: Bool) -> Double {
        let ground = rules(dark: dark).ground.usingColorSpace(.sRGB)!
        let colour = tone.colour.usingColorSpace(.sRGB)!
        let a = colour.alphaComponent
        func over(_ top: CGFloat, _ under: CGFloat) -> CGFloat { top * a + under * (1 - a) }
        let seen = NSColor(srgbRed: over(colour.redComponent, ground.redComponent), green: over(colour.greenComponent, ground.greenComponent),
                           blue: over(colour.blueComponent, ground.blueComponent), alpha: 1)
        return KitMesh.lab(seen).l
    }

    static func calm(_ level: Level) -> Bool { level == .rest }

    static func distinct(_ tones: [Tone]) -> Int {
        var kept: [KitMesh.Lab] = []
        for tone in tones {
            let lab = KitMesh.lab(tone.colour)
            if kept.allSatisfy({ ($0.l - lab.l) * ($0.l - lab.l) + ($0.a - lab.a) * ($0.a - lab.a) + ($0.b - lab.b) * ($0.b - lab.b) >= 0.035 * 0.035 }) {
                kept.append(lab)
            }
        }
        return kept.count
    }

    static func neighbours() -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        for row in 0..<height {
            for column in 0..<width {
                let at = row * width + column
                if column + 1 < width { pairs.append((at, at + 1)) }
                if row + 1 < height { pairs.append((at, at + width)) }
            }
        }
        return pairs
    }

    static func steepest(_ draw: Draw, dark: Bool) -> Double {
        let levels = draw.tones.map { lightness($0, dark: dark) }
        return neighbours().map { abs(levels[$0.0] - levels[$0.1]) }.max() ?? 0
    }

    static func mean(_ draw: Draw, dark: Bool) -> Double {
        draw.tones.map { lightness($0, dark: dark) }.reduce(0, +) / Double(draw.tones.count)
    }

    static func innerSpread(_ draw: Draw, dark: Bool) -> Double {
        let levels = inner.map { lightness(draw.tones[$0], dark: dark) }
        return (levels.max() ?? 0) - (levels.min() ?? 0)
    }

    static let rim: [Int] = (0..<(width * height)).filter { at in
        let row = at / width, column = at % width
        return row == 0 || row == height - 1 || column == 0 || column == width - 1
    }

    static func highlights(_ draw: Draw) -> Int { rim.filter { draw.tones[$0].level == .lift }.count }

    static func openings(_ draw: Draw) -> Int { rim.filter { draw.tones[$0].level == .rest }.count }

    static func flaws(_ draw: Draw, dark: Bool) -> Int {
        let rules = rules(dark: dark)
        var count = 0
        if distinct(draw.tones) < 3 { count += 1 }
        if steepest(draw, dark: dark) > rules.step { count += 1 }
        if !rules.mean.contains(mean(draw, dark: dark)) { count += 1 }
        if !inner.allSatisfy({ calm(draw.tones[$0].level) }) { count += 1 }
        if innerSpread(draw, dark: dark) > rules.calm { count += 1 }
        if highlights(draw) < fewestHighlights { count += 1 }
        if openings(draw) < fewestOpenings { count += 1 }
        return count
    }

    static func roll(_ palette: [Tone], dark: Bool, dice: inout Dice) -> Draw {
        let step = rules(dark: dark).step
        var points: [SIMD2<Swift.Float>] = []
        for row in 0..<height {
            for column in 0..<width {
                var x = Swift.Float(column) / Swift.Float(width - 1)
                var y = Swift.Float(row) / Swift.Float(height - 1)
                if column > 0, column < width - 1 { x += dice.spread(shift) }
                if row > 0, row < height - 1 { y += dice.spread(shift) }
                points.append([x, y])
            }
        }
        var order = Array(palette.indices)
        for index in order.indices.reversed() where index > 0 { order.swapAt(index, dice.below(index + 1)) }
        let fields = min(order.count, palette.count >= 4 && dice.unit() < 0.5 ? 4 : 3)
        let centres: [(SIMD2<Swift.Float>, Swift.Float)] = (0..<fields).map { _ in
            ([Swift.Float(dice.unit() * 1.2 - 0.1), Swift.Float(dice.unit() * 1.2 - 0.1)], Swift.Float(0.75 + dice.unit() * 0.55))
        }
        var tones = points.map { point in
            let nearest = centres.indices.min { one, other in
                let a = point - centres[one].0, b = point - centres[other].0
                return (a * a).sum().squareRoot() / centres[one].1 < (b * b).sum().squareRoot() / centres[other].1
            } ?? 0
            return palette[order[nearest]]
        }
        for index in inner where tones[index].level != .rest {
            let rests = palette.filter { $0.family == tones[index].family && $0.level == .rest }
            tones[index] = rests[dice.below(rests.count)]
        }
        let levels = palette.map { lightness($0, dark: dark) }
        func seen(_ tone: Tone) -> Double { levels[palette.firstIndex(of: tone) ?? 0] }
        for (one, other) in neighbours() where abs(seen(tones[one]) - seen(tones[other])) > step {
            let moved = inner.contains(one) ? other : inner.contains(other) ? one : tones[one].level == .lift ? one : other
            guard let middle = palette.first(where: { $0.family == tones[moved].family && $0.level == .middle }) else { continue }
            tones[moved] = middle
        }
        return Draw(points: points, tones: tones)
    }

    static func draw(_ tint: PinTint, dark: Bool) -> Draw {
        let palette = palette(tint, dark: dark)
        var dice = Dice(state: tint.seed)
        var best: (draw: Draw, flaws: Int)?
        for _ in 0..<attempts {
            let made = roll(palette, dark: dark, dice: &dice)
            let flaws = flaws(made, dark: dark)
            if flaws == 0 { return made }
            if best == nil || flaws < best!.flaws { best = (made, flaws) }
        }
        return best!.draw
    }
}
