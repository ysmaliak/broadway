import AppKit

struct Picture {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(_ path: String) {
        guard let data = FileManager.default.contents(atPath: path), let rep = NSBitmapImageRep(data: data), let image = rep.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        width = image.width
        height = image.height
        var store = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = store.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        bytes = store
    }

    func at(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let i = (y * width + x) * 4
        return (Double(bytes[i]), Double(bytes[i + 1]), Double(bytes[i + 2]))
    }
}

func light(_ c: (Double, Double, Double)) -> Double {
    func line(_ v: Double) -> Double {
        let s = v / 255
        return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * line(c.0) + 0.7152 * line(c.1) + 0.0722 * line(c.2)
}

func contrast(_ a: Double, _ b: Double) -> Double {
    (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

func middle(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
}

@main struct Run {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 5, let with = Picture(args[1]), let blank = Picture(args[2]), let points = Double(args[4]),
              let data = FileManager.default.contents(atPath: args[3]),
              let marks = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            print("usage: ink WITH.png BLANK.png MARKS.json WIDTH-IN-POINTS")
            exit(2)
        }
        guard with.width == blank.width, with.height == blank.height else {
            print("the two stills differ in size")
            exit(2)
        }
        let scale = Double(with.width) / points
        var out: [[String: Any]] = []
        for mark in marks {
            guard let box = mark["box"] as? [Double], box.count == 4 else { continue }
            let x0 = max(0, Int((box[0] * scale).rounded(.down)))
            let y0 = max(0, Int((box[1] * scale).rounded(.down)))
            let x1 = min(with.width, Int(((box[0] + box[2]) * scale).rounded(.up)))
            let y1 = min(with.height, Int(((box[1] + box[3]) * scale).rounded(.up)))
            var said = mark
            guard x1 > x0, y1 > y0 else {
                said["seen"] = 0
                said["worst"] = 0
                out.append(said)
                continue
            }
            var most = 0.0
            var moved: [(Int, Int, Double)] = []
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let a = with.at(x, y)
                    let b = blank.at(x, y)
                    let d = max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
                    if d > 0 { moved.append((x, y, d)) }
                    most = max(most, d)
                }
            }
            said["seen"] = most
            guard most >= 6 else {
                said["worst"] = 1.0
                said["typical"] = 1.0
                out.append(said)
                continue
            }
            let core = moved.filter { $0.2 >= most * 0.8 }
            let ink = (middle(core.map { with.at($0.0, $0.1).0 }), middle(core.map { with.at($0.0, $0.1).1 }), middle(core.map { with.at($0.0, $0.1).2 }))
            let inked = light(ink)
            var each: [Double] = []
            each.reserveCapacity((x1 - x0) * (y1 - y0))
            var behind = (0.0, 0.0, 0.0)
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let b = blank.at(x, y)
                    each.append(contrast(inked, light(b)))
                    behind = (behind.0 + b.0, behind.1 + b.1, behind.2 + b.2)
                }
            }
            each.sort()
            let count = Double(each.count)
            said["ink"] = [ink.0, ink.1, ink.2]
            said["behind"] = [(behind.0 / count).rounded(), (behind.1 / count).rounded(), (behind.2 / count).rounded()]
            said["worst"] = (each[min(each.count - 1, each.count * 3 / 100)] * 100).rounded() / 100
            said["typical"] = (each[each.count / 2] * 100).rounded() / 100
            out.append(said)
        }
        let answer = try JSONSerialization.data(withJSONObject: out)
        FileHandle.standardOutput.write(answer)
    }
}
