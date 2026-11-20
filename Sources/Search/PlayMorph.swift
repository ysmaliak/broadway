import AppKit

struct PlayShape: Equatable {
    var left: CGFloat
    var right: CGFloat
    var topLeft: CGFloat
    var bottomLeft: CGFloat
    var topRight: CGFloat
    var bottomRight: CGFloat
    var split: CGFloat
    var gap: CGFloat
    var round: CGFloat

    func mixed(_ other: PlayShape, _ t: CGFloat) -> PlayShape {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        return PlayShape(left: mix(left, other.left), right: mix(right, other.right), topLeft: mix(topLeft, other.topLeft),
                         bottomLeft: mix(bottomLeft, other.bottomLeft), topRight: mix(topRight, other.topRight),
                         bottomRight: mix(bottomRight, other.bottomRight), split: mix(split, other.split), gap: mix(gap, other.gap),
                         round: mix(round, other.round))
    }

    func moved(_ x: CGFloat, _ y: CGFloat) -> PlayShape {
        PlayShape(left: left + x, right: right + x, topLeft: topLeft + y, bottomLeft: bottomLeft + y, topRight: topRight + y,
                  bottomRight: bottomRight + y, split: split + x, gap: gap, round: round)
    }

    func flipped(in height: CGFloat) -> PlayShape {
        PlayShape(left: left, right: right, topLeft: height - topLeft, bottomLeft: height - bottomLeft, topRight: height - topRight,
                  bottomRight: height - bottomRight, split: split, gap: gap, round: round)
    }

    var path: CGPath {
        let wide = max(right - left, 0.001)
        func top(_ x: CGFloat) -> CGFloat { topLeft + (topRight - topLeft) * (x - left) / wide }
        func bottom(_ x: CGFloat) -> CGFloat { bottomLeft + (bottomRight - bottomLeft) * (x - left) / wide }
        let near = split - gap / 2, far = split + gap / 2
        let made = CGMutablePath()
        made.addLines(between: [CGPoint(x: left, y: topLeft), CGPoint(x: near, y: top(near)), CGPoint(x: near, y: bottom(near)),
                                CGPoint(x: left, y: bottomLeft)])
        made.closeSubpath()
        made.addLines(between: [CGPoint(x: far, y: top(far)), CGPoint(x: right, y: topRight), CGPoint(x: right, y: bottomRight),
                                CGPoint(x: far, y: bottom(far))])
        made.closeSubpath()
        return made
    }
}

@MainActor
enum PlayMorph {
    static let key = "play.morph"
    static let fadeKey = "play.morph.fade"
    static let fade: CFTimeInterval = 0.1
    static let response = 0.34
    static let fuse: CGFloat = 1.4
    static let rate = 120.0

    static func progress(_ elapsed: Double) -> CGFloat {
        guard elapsed > 0 else { return 0 }
        let turn = 2 * Double.pi / response * elapsed
        return min(1, CGFloat(1 - (1 + turn) * exp(-turn)))
    }

    static func at(_ from: PlayShape, _ to: PlayShape, _ elapsed: Double) -> PlayShape {
        let done = progress(elapsed)
        var shape = from.mixed(to, done)
        shape.gap = from.gap + (to.gap - from.gap) * min(1, done * fuse)
        return shape
    }

    static let duration: Double = {
        var steps = 1.0
        while progress(steps / rate) < 0.998 { steps += 1 }
        return steps / rate
    }()

    private static var fitted: [String: PlayShape] = [:]
    private static var missed: Set<String> = []

    static func shape(_ name: String, _ style: KitSymbol.Style, in box: CGSize, scale: CGFloat) -> PlayShape? {
        let key = "\(name) \(style.size) \(style.weight.rawValue) \(style.scale.rawValue) \(box.width) \(box.height) \(scale)"
        if let known = fitted[key] { return known }
        guard !missed.contains(key), box.width >= 1, box.height >= 1, let image = KitGlyph.image(name, style),
              let ink = Ink(image, in: box, scale: scale) else { return nil }
        let found = name.hasPrefix("pause") ? ink.pause() : name.hasPrefix("play") ? ink.play() : nil
        if let found { fitted[key] = found } else { missed.insert(key) }
        return found
    }

    nonisolated static func origin(of size: CGSize, in box: CGSize) -> CGPoint {
        CGPoint(x: ((box.width - size.width) / 2).rounded(), y: ((box.height - size.height) / 2).rounded())
    }

    private struct Ink {
        let scale: CGFloat
        let wide: Int
        let high: Int
        let alpha: [UInt8]

        init?(_ image: NSImage, in box: CGSize, scale: CGFloat) {
            self.scale = scale
            wide = max(1, Int((box.width * scale).rounded()))
            high = max(1, Int((box.height * scale).rounded()))
            let at = PlayMorph.origin(of: image.size, in: box)
            guard let drawn = Self.draw(wide, high, scale, { context in
                let shown = NSGraphicsContext(cgContext: context, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = shown
                image.draw(in: NSRect(origin: at, size: image.size))
                NSGraphicsContext.restoreGraphicsState()
            }) else { return nil }
            alpha = drawn
        }

        static func draw(_ wide: Int, _ high: Int, _ scale: CGFloat, _ paint: (CGContext) -> Void) -> [UInt8]? {
            var data = [UInt8](repeating: 0, count: wide * high * 4)
            let made = data.withUnsafeMutableBytes { bytes -> Bool in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: bytes.baseAddress, width: wide, height: high, bitsPerComponent: 8, bytesPerRow: wide * 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.scaleBy(x: scale, y: scale)
                paint(context)
                return true
            }
            return made ? stride(from: 3, to: data.count, by: 4).map { data[$0] } : nil
        }

        func box(_ from: Int = 0, _ to: Int? = nil) -> CGRect? {
            var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
            for y in 0..<high {
                for x in from..<(to ?? wide) where alpha[y * wide + x] > 127 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
            guard maxX >= minX else { return nil }
            let height = CGFloat(high) / scale
            return CGRect(x: CGFloat(minX) / scale, y: height - CGFloat(maxY + 1) / scale, width: CGFloat(maxX + 1 - minX) / scale,
                          height: CGFloat(maxY + 1 - minY) / scale)
        }

        func column(_ x: Int) -> Int {
            var sum = 0
            for y in 0..<high { sum += Int(alpha[y * wide + x]) }
            return sum
        }

        func miss(_ shape: PlayShape) -> Int {
            guard shape.round >= 0, let drawn = Self.draw(wide, high, scale, { context in
                context.setFillColor(gray: 1, alpha: 1)
                context.setStrokeColor(gray: 1, alpha: 1)
                context.addPath(shape.path)
                context.fillPath()
                guard shape.round > 0 else { return }
                context.setLineWidth(shape.round * 2)
                context.setLineJoin(.round)
                context.addPath(shape.path)
                context.strokePath()
            }) else { return .max }
            var sum = 0
            for index in alpha.indices { sum += abs(Int(alpha[index]) - Int(drawn[index])) }
            return sum
        }

        func tuned(_ start: PlayShape, _ knobs: [WritableKeyPath<PlayShape, CGFloat>], tied: [WritableKeyPath<PlayShape, CGFloat>: WritableKeyPath<PlayShape, CGFloat>] = [:]) -> PlayShape {
            var shape = start
            var least = miss(shape)
            for step: CGFloat in [0.2, 0.1, 0.05, 0.025] {
                var better = true
                var rounds = 0
                while better, rounds < 12 {
                    better = false
                    rounds += 1
                    for knob in knobs {
                        for sign: CGFloat in [1, -1] {
                            var tried = shape
                            tried[keyPath: knob] += step * sign
                            if let twin = tied[knob] { tried[keyPath: twin] += step * sign }
                            let missed = miss(tried)
                            if missed < least {
                                least = missed
                                shape = tried
                                better = true
                            }
                        }
                    }
                }
            }
            return shape
        }

        func pause() -> PlayShape? {
            guard let whole = box() else { return nil }
            let from = Int((whole.minX + whole.width / 4) * scale), to = Int((whole.maxX - whole.width / 4) * scale)
            guard from < to else { return nil }
            let columns = (from...to).map { ($0, column($0)) }
            let fullest = (Int((whole.minX * scale).rounded())..<Int((whole.maxX * scale).rounded())).map(column).max() ?? 0
            guard let faintest = columns.min(by: { $0.1 < $1.1 }), faintest.1 * 2 < fullest,
                  let first = box(0, faintest.0), let second = box(faintest.0 + 1, wide) else { return nil }
            let round = min(first.width, second.width) / 4
            let a = first.insetBy(dx: round, dy: round), b = second.insetBy(dx: round, dy: round)
            let start = PlayShape(left: a.minX, right: b.maxX, topLeft: a.maxY, bottomLeft: a.minY, topRight: b.maxY, bottomRight: b.minY,
                                  split: (a.maxX + b.minX) / 2, gap: b.minX - a.maxX, round: round)
            return tuned(start, [\.left, \.right, \.topLeft, \.bottomLeft, \.topRight, \.bottomRight, \.split, \.gap, \.round])
        }

        func play() -> PlayShape? {
            guard let whole = box(), whole.width > 1, whole.height > 1 else { return nil }
            let round = min(whole.width, whole.height) / 10
            let left = whole.minX + round, right = whole.maxX - round
            let start = PlayShape(left: left, right: right, topLeft: whole.maxY - round, bottomLeft: whole.minY + round, topRight: whole.midY,
                                  bottomRight: whole.midY, split: (left + right) / 2, gap: 0, round: round)
            var shape = tuned(start, [\.left, \.right, \.topLeft, \.bottomLeft, \.topRight, \.round], tied: [\.topRight: \.bottomRight])
            shape.split = (shape.left + shape.right) / 2
            return shape
        }
    }
}
