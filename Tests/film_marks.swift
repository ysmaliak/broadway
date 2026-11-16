import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: film_marks FRAMES_DIR COLUMN(x,y,w,h unit) PAGE(x,y,w,h unit) [REFERENCE_FRAME]\n".data(using: .utf8)!)
    exit(2)
}

func unit(_ text: String) -> CGRect {
    let n = text.split(separator: ",").compactMap { Double($0) }
    return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : .zero
}

let folder = URL(fileURLWithPath: args[1])
let column = unit(args[2])
let page = unit(args[3])

struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = data
    }

    func grey(_ x: Int, _ y: Int) -> Int {
        let i = (y * width + x) * 4
        return (Int(bytes[i]) * 3 + Int(bytes[i + 1]) * 6 + Int(bytes[i + 2])) / 10
    }

    func box(_ r: CGRect) -> (Int, Int, Int, Int) {
        (Int(r.minX * Double(width)), Int(r.minY * Double(height)), Int(r.maxX * Double(width)), Int(r.maxY * Double(height)))
    }

    func spread(_ r: CGRect) -> Double {
        let (x0, y0, x1, y1) = box(r)
        var sum = 0.0, square = 0.0, count = 0.0
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                let g = Double(grey(x, y))
                sum += g
                square += g * g
                count += 1
                x += 2
            }
            y += 2
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return (square / count - mean * mean).squareRoot()
    }

    func ink(_ r: CGRect) -> Int {
        let (x0, y0, x1, y1) = box(r)
        var count = 0
        for y in max(1, y0)..<min(height - 1, y1) {
            for x in max(1, x0)..<min(width - 1, x1) {
                let here = grey(x, y)
                if abs(here - grey(x + 1, y)) > 40 || abs(here - grey(x, y + 1)) > 40 { count += 1 }
            }
        }
        return count
    }

    func bands(_ r: CGRect, _ step: Int) -> [Double] {
        let (x0, y0, x1, y1) = box(r)
        var out: [Double] = []
        var x = max(1, x0)
        while x < min(width - 1, x1) {
            var count = 0
            for y in max(1, y0)..<min(height - 1, y1) {
                for dx in x..<min(x + step, width - 1) {
                    let here = grey(dx, y)
                    if abs(here - grey(dx + 1, y)) > 40 || abs(here - grey(dx, y + 1)) > 40 { count += 1 }
                }
            }
            out.append(Double(count))
            x += step
        }
        return out
    }

    func apart(_ other: Pixels, _ r: CGRect) -> Double {
        let (x0, y0, x1, y1) = box(r)
        var best = Double.infinity
        for dx in -6...6 {
            var sum = 0, count = 0
            var y = max(0, y0)
            while y < min(height, y1) {
                var x = max(6, x0)
                while x < min(width - 6, x1) {
                    sum += abs(grey(x, y) - other.grey(x + dx, y))
                    count += 1
                    x += 2
                }
                y += 2
            }
            if count > 0 { best = min(best, Double(sum) / Double(count)) }
        }
        return best.isFinite ? best : 0
    }
}

let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "png" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
func load(_ url: URL) -> Pixels? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return Pixels(image)
}
let reference = args.count > 4 ? Int(args[4]) : nil
let last = (reference.flatMap { index in files.first { Int($0.deletingPathExtension().lastPathComponent) == index } } ?? files.last).flatMap(load)
var out: [String: [Double]] = [:]
for url in files {
    guard let index = Int(url.deletingPathExtension().lastPathComponent), let pixels = load(url) else { continue }
    let round = { (value: Double) in (value * 10).rounded() / 10 }
    out[String(index)] = [round(pixels.spread(page)), Double(pixels.ink(column)),
                          round(last.map { pixels.apart($0, page) } ?? 0), round(last.map { pixels.apart($0, column) } ?? 0)]
        + pixels.bands(column, 2)
}
let json = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
FileHandle.standardOutput.write(json)
