import AppKit

enum KitMesh {
    struct Lab {
        var l: Double
        var a: Double
        var b: Double
        var alpha: Double

        static func + (x: Lab, y: Lab) -> Lab { Lab(l: x.l + y.l, a: x.a + y.a, b: x.b + y.b, alpha: x.alpha + y.alpha) }
        static func * (x: Lab, k: Double) -> Lab { Lab(l: x.l * k, a: x.a * k, b: x.b * k, alpha: x.alpha * k) }
    }

    static func lab(_ colour: NSColor) -> Lab {
        let c = colour.usingColorSpace(.sRGB) ?? colour
        func linear(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = linear(c.redComponent), g = linear(c.greenComponent), b = linear(c.blueComponent)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return Lab(l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                   a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                   b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
                   alpha: Double(c.alphaComponent))
    }

    static func rgb(_ lab: Lab) -> (Double, Double, Double, Double) {
        let l = pow(lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b, 3)
        let m = pow(lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b, 3)
        let s = pow(lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b, 3)
        func gamma(_ v: Double) -> Double {
            let v = max(0, min(1, v))
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return (gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
                max(0, min(1, lab.alpha)))
    }

    private static func hermite(_ p0: Lab, _ p1: Lab, _ p2: Lab, _ p3: Lab, _ t: Double) -> Lab {
        let t2 = t * t, t3 = t2 * t
        let m1 = (p2 + p0 * -1) * 0.5
        let m2 = (p3 + p1 * -1) * 0.5
        return p1 * (2 * t3 - 3 * t2 + 1) + m1 * (t3 - 2 * t2 + t) + p2 * (-2 * t3 + 3 * t2) + m2 * (t3 - t2)
    }

    private static func locate(_ x: Double, _ y: Double, points: [SIMD2<Double>], width: Int, height: Int) -> (Double, Double) {
        var best: (Double, Double, Double) = (0, 0, .infinity)
        let rows = height - 1, columns = width - 1
        let guessRow = min(rows - 1, max(0, Int(y * Double(rows))))
        let guessColumn = min(columns - 1, max(0, Int(x * Double(columns))))
        func inside(_ row: Int, _ column: Int) -> Bool {
            let p00 = points[row * width + column], p10 = points[row * width + column + 1]
            let p01 = points[(row + 1) * width + column], p11 = points[(row + 1) * width + column + 1]
            var u = 0.5, v = 0.5
            for _ in 0..<12 {
                let p = p00 * ((1 - u) * (1 - v)) + p10 * (u * (1 - v)) + p01 * ((1 - u) * v) + p11 * (u * v)
                let du = (p10 - p00) * (1 - v) + (p11 - p01) * v
                let dv = (p01 - p00) * (1 - u) + (p11 - p10) * u
                let ex = p.x - x, ey = p.y - y
                let det = du.x * dv.y - du.y * dv.x
                guard abs(det) > 1e-12 else { break }
                u -= (ex * dv.y - ey * dv.x) / det
                v -= (du.x * ey - du.y * ex) / det
            }
            let reached = p00 * ((1 - u) * (1 - v)) + p10 * (u * (1 - v)) + p01 * ((1 - u) * v) + p11 * (u * v)
            let miss = abs(reached.x - x) + abs(reached.y - y)
            let outside = max(0, -u, u - 1) + max(0, -v, v - 1) + (miss > 1e-7 ? 1 + miss : 0)
            if outside < best.2 {
                best = (Double(column) + min(1, max(0, u)), Double(row) + min(1, max(0, v)), outside)
            }
            return outside == 0
        }
        for ring in 0...max(rows, columns) {
            let top = guessRow - ring, bottom = guessRow + ring, left = guessColumn - ring, right = guessColumn + ring
            for row in max(0, top)...min(rows - 1, bottom) {
                let edge = row == top || row == bottom
                var column = max(0, left)
                while column <= min(columns - 1, right) {
                    if inside(row, column) { return (best.0, best.1) }
                    column = edge || column == right ? column + 1 : right
                }
            }
        }
        return (best.0, best.1)
    }

    static func image(width: Int, height: Int, points: [SIMD2<Swift.Float>], colours: [NSColor], size: CGSize, scale: CGFloat) -> NSImage {
        let pixelsWide = Int((size.width * scale).rounded())
        let pixelsHigh = Int((size.height * scale).rounded())
        let grid = points.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
        let labs = colours.map(lab)
        func at(_ row: Int, _ column: Int) -> Lab {
            labs[min(height - 1, max(0, row)) * width + min(width - 1, max(0, column))]
        }
        var bytes = [UInt8](repeating: 0, count: pixelsWide * pixelsHigh * 4)
        for py in 0..<pixelsHigh {
            for px in 0..<pixelsWide {
                let x = (Double(px) + 0.5) / Double(pixelsWide)
                let y = (Double(py) + 0.5) / Double(pixelsHigh)
                let (gu, gv) = locate(x, y, points: grid, width: width, height: height)
                let column = min(width - 2, Int(gu)), row = min(height - 2, Int(gv))
                let tu = gu - Double(column), tv = gv - Double(row)
                func line(_ r: Int) -> Lab {
                    hermite(at(r, column - 1), at(r, column), at(r, column + 1), at(r, column + 2), tu)
                }
                let colour = rgb(hermite(line(row - 1), line(row), line(row + 1), line(row + 2), tv))
                let index = (py * pixelsWide + px) * 4
                bytes[index] = UInt8((colour.0 * colour.3 * 255).rounded())
                bytes[index + 1] = UInt8((colour.1 * colour.3 * 255).rounded())
                bytes[index + 2] = UInt8((colour.2 * colour.3 * 255).rounded())
                bytes[index + 3] = UInt8((colour.3 * 255).rounded())
            }
        }
        let image = NSImage(size: size)
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let cg = CGImage(width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixelsWide * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return image }
        image.addRepresentation(NSBitmapImageRep(cgImage: cg))
        return image
    }
}
