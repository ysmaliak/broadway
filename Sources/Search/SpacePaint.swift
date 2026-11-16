import AppKit

enum Paint {
    static let title = 0.90
    static let quiet = 0.49
    static let titleContrast = 4.6
    static let quietContrast = 3.0
    static let darkInk = 0.09
    static let lightInk = 0.93
    static let liftedTitle = 1.0
    static let liftedQuiet = 0.8

    struct Ground: Equatable {
        var stops: [Oklch]
        var lightInk: Bool
        var lift: Double = 0

        var average: Oklch {
            guard stops.count > 1 else { return stops.first ?? Oklch(l: 0.9, c: 0, h: 0) }
            let a = stops.map { $0.c * cos($0.h * .pi / 180) }.reduce(0, +) / Double(stops.count)
            let b = stops.map { $0.c * sin($0.h * .pi / 180) }.reduce(0, +) / Double(stops.count)
            let l = stops.map(\.l).reduce(0, +) / Double(stops.count)
            return Oklch(l: l, c: (a * a + b * b).squareRoot(), h: (atan2(b, a) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360))
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Ground] = [:]

    static func ground(_ hexes: [String], intensity: Double, dark: Bool) -> Ground {
        let key = "\(hexes.joined(separator: ","))|\(intensity)|\(dark)"
        lock.lock()
        if let known = cache[key] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let made = ground(hexes.map { Oklch(hex: $0) }, intensity: intensity, dark: dark)
        lock.lock()
        if cache.count > 512 { cache.removeAll() }
        cache[key] = made
        lock.unlock()
        return made
    }

    static func ground(_ colours: [Oklch], intensity: Double, dark: Bool) -> Ground {
        let bold = calm(colours, intensity: min(1, intensity), dark: dark)
        guard intensity > 1, !colours.isEmpty else { return bold }
        let t = min(1, intensity - 1)
        let ease = t * t * (3 - 2 * t)
        let wide = colours.contains { !$0.inGamut }
        let stops = zip(bold.stops, colours.prefix(3)).map { mixed($0, $1, ease, wide: wide) }
        return inked(stops)
    }

    static func mixed(_ from: Oklch, _ to: Oklch, _ share: Double, wide: Bool) -> Oklch {
        if share >= 1 { return to }
        if share <= 0 { return from }
        let a = (from.c * cos(from.h * .pi / 180), from.c * sin(from.h * .pi / 180))
        let b = (to.c * cos(to.h * .pi / 180), to.c * sin(to.h * .pi / 180))
        let x = a.0 + (b.0 - a.0) * share, y = a.1 + (b.1 - a.1) * share
        let c = (x * x + y * y).squareRoot()
        let h = c < 0.0001 ? (to.c > from.c ? to.h : from.h) : (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return gamut(Oklch(l: from.l + (to.l - from.l) * share, c: c, h: h), wide: wide)
    }

    static func ink(light: Bool, lift: Double) -> Double {
        light ? lightInk + (1 - lightInk) * lift : darkInk * (1 - lift)
    }

    static func titleAlpha(_ lift: Double) -> Double { title + (liftedTitle - title) * lift }
    static func quietAlpha(_ lift: Double) -> Double { quiet + (liftedQuiet - quiet) * lift }

    static func reads(_ ground: Oklch, light: Bool, lift: Double) -> Bool {
        let level = ink(light: light, lift: lift)
        return contrast(ink: level, alpha: titleAlpha(lift), on: ground) >= titleContrast
            && contrast(ink: level, alpha: quietAlpha(lift), on: ground) >= quietContrast
    }

    static func lift(for ground: Oklch, light: Bool) -> Double? {
        if reads(ground, light: light, lift: 0) { return 0 }
        guard reads(ground, light: light, lift: 1) else { return nil }
        var low = 0.0, high = 1.0
        for _ in 0..<14 {
            let mid = (low + high) / 2
            if reads(ground, light: light, lift: mid) { high = mid } else { low = mid }
        }
        return high
    }

    static func inked(_ stops: [Oklch]) -> Ground {
        func need(_ light: Bool) -> Double { stops.map { Self.lift(for: $0, light: light) ?? 2 }.max() ?? 0 }
        let forLight = need(true), forDark = need(false)
        let light: Bool
        if forLight == forDark {
            let reach = stops.map { contrast(ink: 1, alpha: 1, on: $0) - contrast(ink: 0, alpha: 1, on: $0) }.reduce(0, +)
            light = reach >= 0
        } else {
            light = forLight < forDark
        }
        let settledStops = stops.map { stop -> Oklch in
            guard Self.lift(for: stop, light: light) == nil else { return stop }
            var out = stop
            for _ in 0..<200 where !reads(out, light: light, lift: 1) {
                out = gamut(Oklch(l: min(1, max(0, out.l + (light ? -0.002 : 0.002))), c: stop.c, h: stop.h), wide: !stop.inGamut)
            }
            return out
        }
        let lift = settledStops.map { Self.lift(for: $0, light: light) ?? 1 }.max() ?? 0
        return Ground(stops: settledStops, lightInk: light, lift: lift)
    }

    static func calm(_ colours: [Oklch], intensity: Double, dark: Bool) -> Ground {
        let mapped = colours.prefix(3).map { painted($0, intensity: intensity, dark: dark) }
        guard !mapped.isEmpty else { return Ground(stops: [Oklch(l: dark ? 0.255 : 0.945, c: 0, h: 0)], lightInk: dark) }
        let lean = mapped.map { lightInkLean($0, dark: dark) }.reduce(0, +)
        let light = lean == 0 ? dark : lean > 0
        return Ground(stops: mapped.map { settled($0, lightInk: light) }, lightInk: light)
    }

    static func painted(_ source: Oklch, intensity: Double, dark: Bool) -> Oklch {
        let t = min(1, max(0, intensity))
        let full = dark ? deep(source) : vivid(source)
        let base = Oklch(l: dark ? 0.255 : 0.955, c: source.c < 0.012 ? 0 : min(dark ? 0.02 : 0.016, source.c * 0.2), h: source.h)
        let ease = t * t * (3 - 2 * t) * 0.4 + t * 0.6
        return gamut(Oklch(l: base.l + (full.l - base.l) * ease, c: base.c + (full.c - base.c) * t, h: full.c > 0 ? full.h : source.h))
    }

    static func vivid(_ source: Oklch) -> Oklch {
        let l = min(0.97, max(0.2, source.l))
        let cap = chromaCap(l: l, h: source.h)
        let c = source.c < 0.012 ? 0 : cap * tanh(source.c / cap)
        let rich = c > 0.12 && l > 0.88 ? l - (l - 0.88) * 0.5 : l
        return gamut(Oklch(l: rich, c: c, h: source.h))
    }

    static func deep(_ source: Oklch) -> Oklch {
        let l = min(1, max(0, source.l))
        let olive = source.h > 85 && source.h < 128
        let hue = olive ? source.h - (source.h - 75) * 0.45 : source.h
        let depth = 0.2 + 0.12 * l
        let cap = olive ? 0.055 : 0.13
        let c = source.c < 0.012 ? 0 : cap * tanh(source.c / cap)
        return gamut(Oklch(l: depth, c: c, h: hue))
    }

    static func lightInkLean(_ ground: Oklch, dark: Bool) -> Int {
        if dark {
            return contrast(ink: darkInk, alpha: title, on: ground) > contrast(ink: lightInk, alpha: title, on: ground) * 1.2 ? -1 : 1
        }
        if ground.c >= 0.09 && ground.l < 0.72 { return 1 }
        return contrast(ink: lightInk, alpha: title, on: ground) > contrast(ink: darkInk, alpha: title, on: ground) ? 1 : -1
    }

    static func chromaCap(l: Double, h: Double) -> Double {
        let warm = h > 85 && h < 125
        if l <= 0.62 { return 0.12 + 0.08 * max(0, l - 0.2) / 0.42 }
        let top = warm ? 0.16 : 0.1
        return 0.2 - (0.2 - top) * min(1, (l - 0.62) / 0.35)
    }

    static func gamut(_ colour: Oklch, wide: Bool = false) -> Oklch {
        func fits(_ c: Oklch) -> Bool { wide ? c.inP3 : c.inGamut }
        if colour.l <= 0 { return Oklch(l: 0, c: 0, h: colour.h) }
        if colour.l >= 1 { return Oklch(l: 1, c: 0, h: colour.h) }
        guard !fits(colour) else { return colour }
        var low = 0.0, high = colour.c
        for _ in 0..<18 {
            let mid = (low + high) / 2
            if fits(Oklch(l: colour.l, c: mid, h: colour.h)) { low = mid } else { high = mid }
        }
        return Oklch(l: colour.l, c: low, h: colour.h)
    }

    static func settled(_ colour: Oklch, lightInk: Bool) -> Oklch {
        var out = colour
        let ink = lightInk ? Self.lightInk : darkInk
        for _ in 0..<200 {
            if contrast(ink: ink, alpha: title, on: out) >= titleContrast,
               contrast(ink: ink, alpha: quiet, on: out) >= quietContrast { return out }
            out = gamut(Oklch(l: min(1, max(0, out.l + (lightInk ? -0.005 : 0.005))), c: colour.c, h: colour.h))
        }
        return out
    }

    static func contrast(ink: Double, alpha: Double, on ground: Oklch) -> Double {
        let g = ground.inGamut ? ground.rgb : ground.extended
        let mixed = (g.r + (ink - g.r) * alpha, g.g + (ink - g.g) * alpha, g.b + (ink - g.b) * alpha)
        return ratio(luminance(mixed), luminance(g))
    }

    static func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    static func ratio(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

extension Oklch {
    var linear: (r: Double, g: Double, b: Double) {
        let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let (x, y, z) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
        return (4.0767416621 * x - 3.3077115913 * y + 0.2309699292 * z,
                -1.2684380046 * x + 2.6097574011 * y - 0.3413193965 * z,
                -0.0041960863 * x - 0.7034186147 * y + 1.7076147010 * z)
    }

    var inGamut: Bool {
        let v = linear
        let e = 0.0005
        return v.r >= -e && v.r <= 1 + e && v.g >= -e && v.g <= 1 + e && v.b >= -e && v.b <= 1 + e
    }

    var p3Linear: (r: Double, g: Double, b: Double) {
        let v = linear
        return (0.8224621 * v.r + 0.1775380 * v.g,
                0.0331941 * v.r + 0.9668058 * v.g,
                0.0170827 * v.r + 0.0723974 * v.g + 0.9105199 * v.b)
    }

    var inP3: Bool {
        let v = p3Linear
        let e = 0.0005
        return v.r >= -e && v.r <= 1 + e && v.g >= -e && v.g <= 1 + e && v.b >= -e && v.b <= 1 + e
    }

    var extended: (r: Double, g: Double, b: Double) {
        let v = linear
        return (Oklch.signed(v.r), Oklch.signed(v.g), Oklch.signed(v.b))
    }

    var p3: (r: Double, g: Double, b: Double) {
        let v = p3Linear
        return (Oklch.encoded(v.r), Oklch.encoded(v.g), Oklch.encoded(v.b))
    }

    var code: String {
        guard !inGamut else { return hex }
        let v = p3
        return "p3:" + String(format: "%02X%02X%02X", Int((v.r * 255).rounded()), Int((v.g * 255).rounded()), Int((v.b * 255).rounded()))
    }

    static func signed(_ v: Double) -> Double {
        let x = abs(v)
        let e = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        return v < 0 ? -e : e
    }
}

struct Oklch: Equatable {
    var l: Double
    var c: Double
    var h: Double

    init(l: Double, c: Double, h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }

    init(hex: String) {
        let r: Double, g: Double, b: Double
        if let wide = NSColor.p3Components(hex) {
            let (pr, pg, pb) = (Oklch.linear(wide.0), Oklch.linear(wide.1), Oklch.linear(wide.2))
            r = 1.2249401 * pr - 0.2249404 * pg
            g = -0.0420569 * pr + 1.0420571 * pg
            b = -0.0196376 * pr - 0.0786361 * pg + 1.0982735 * pb
        } else {
            let source = NSColor(hexString: hex).usingColorSpace(.sRGB) ?? .gray
            r = Oklch.linear(source.redComponent)
            g = Oklch.linear(source.greenComponent)
            b = Oklch.linear(source.blueComponent)
        }
        let l_ = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m_ = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s_ = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lab = (0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
                   1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
                   0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
        l = lab.0
        c = (lab.1 * lab.1 + lab.2 * lab.2).squareRoot()
        h = (atan2(lab.2, lab.1) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    var rgb: (r: Double, g: Double, b: Double) {
        let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let (x, y, z) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
        return (Oklch.encoded(4.0767416621 * x - 3.3077115913 * y + 0.2309699292 * z),
                Oklch.encoded(-1.2684380046 * x + 2.6097574011 * y - 0.3413193965 * z),
                Oklch.encoded(-0.0041960863 * x - 0.7034186147 * y + 1.7076147010 * z))
    }

    var color: NSColor {
        guard inGamut else {
            let v = p3
            return NSColor(displayP3Red: v.r, green: v.g, blue: v.b, alpha: 1)
        }
        let v = rgb
        return NSColor(srgbRed: v.r, green: v.g, blue: v.b, alpha: 1)
    }

    var hex: String {
        let v = rgb
        return String(format: "%02X%02X%02X", Int((v.r * 255).rounded()), Int((v.g * 255).rounded()), Int((v.b * 255).rounded()))
    }

    private static func linear(_ v: CGFloat) -> Double {
        let x = Double(v)
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ v: Double) -> Double {
        let x = min(1, max(0, v))
        return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }
}

extension NSColor {
    static func p3Components(_ code: String) -> (CGFloat, CGFloat, CGFloat)? {
        guard code.lowercased().hasPrefix("p3:"), let value = UInt32(code.dropFirst(3), radix: 16) else { return nil }
        return (CGFloat((value >> 16) & 255) / 255, CGFloat((value >> 8) & 255) / 255, CGFloat(value & 255) / 255)
    }

    var code: String {
        guard let c = usingColorSpace(.extendedSRGB) else { return hexString }
        let e = 0.6 / 255
        let fits = [c.redComponent, c.greenComponent, c.blueComponent].allSatisfy { $0 >= -e && $0 <= 1 + e }
        guard !fits, let p = usingColorSpace(.displayP3) else { return hexString }
        return "p3:" + String(format: "%02X%02X%02X", Int(p.redComponent * 255 + 0.5), Int(p.greenComponent * 255 + 0.5),
                              Int(p.blueComponent * 255 + 0.5))
    }

    convenience init(hexString: String) {
        if let wide = NSColor.p3Components(hexString) {
            self.init(displayP3Red: wide.0, green: wide.1, blue: wide.2, alpha: 1)
            return
        }
        let value = UInt32(hexString, radix: 16) ?? 0xE5E5E5
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "E5E5E5" }
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255 + 0.5), Int(c.greenComponent * 255 + 0.5),
                      Int(c.blueComponent * 255 + 0.5))
    }
}
