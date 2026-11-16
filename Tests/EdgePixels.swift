import AppKit

@main struct Run {
    static func load(_ path: String) -> NSBitmapImageRep? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return NSBitmapImageRep(data: data)
    }

    static func hex(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> String {
        var pixel = [Int](repeating: 0, count: 4)
        rep.getPixel(&pixel, atX: x, y: y)
        return String(format: "%02X%02X%02X", pixel[0], pixel[1], pixel[2])
    }

    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: EdgePixels column PNG X Y0 Y1 | row PNG Y X0 X1 | box PNG X Y W H | foot PNG X0 X1 | crop PNG X Y W H SCALE OUT | many PNG JOB… | differ PNG PNG X Y W H | onscreen PID")
            return
        }
        if args[1] == "differ" {
            guard args.count >= 8, let one = load(args[2]), let other = load(args[3]) else { return print("unreadable") }
            let box = args[4...7].map { Int($0) ?? 0 }
            let right = min(box[0] + box[2], one.pixelsWide, other.pixelsWide)
            let low = min(box[1] + box[3], one.pixelsHigh, other.pixelsHigh)
            var count = 0
            var most = 0
            var rows: [Int] = []
            var columns: ClosedRange<Int>?
            var a = [Int](repeating: 0, count: 4)
            var b = [Int](repeating: 0, count: 4)
            for y in box[1]..<max(box[1], low) {
                var differs = false
                for x in box[0]..<max(box[0], right) {
                    one.getPixel(&a, atX: x, y: y)
                    other.getPixel(&b, atX: x, y: y)
                    let apart = max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2]))
                    if apart > 2 {
                        count += 1
                        most = max(most, apart)
                        columns = min(columns?.lowerBound ?? x, x)...max(columns?.upperBound ?? x, x)
                        differs = true
                    }
                }
                if differs { rows.append(y) }
            }
            let sizes = one.pixelsWide == other.pixelsWide && one.pixelsHigh == other.pixelsHigh ? "same size" : "sizes differ"
            let place = columns.map { "x \($0.lowerBound) to \($0.upperBound), y \(rows.first ?? 0) to \(rows.last ?? 0), at most \(most) of 255 apart" } ?? "nowhere"
            return print("\(count) px differ: \(place) (\(sizes))")
        }
        if args[1] == "onscreen" {
            let pid = Int(args[2]) ?? 0
            let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            for window in list where window[kCGWindowOwnerPID as String] as? Int == pid && window[kCGWindowLayer as String] as? Int == 0 {
                let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
                print("\(window[kCGWindowNumber as String] ?? 0)\t\(window[kCGWindowIsOnscreen as String] as? Bool == true ? "onscreen" : "offscreen")\t\(Int(bounds["Width"] ?? 0))x\(Int(bounds["Height"] ?? 0))")
            }
            return
        }
        guard let rep = load(args[2]) else { print("no picture"); return }
        var rest = Array(args.dropFirst(3))
        if args[1] != "many" { rest.insert(args[1], at: 0) }
        var jobs: [[String]] = []
        for word in rest {
            if Int(word) == nil, word != rest.last || jobs.isEmpty || jobs[jobs.count - 1][0] != "crop" {
                jobs.append([word])
            } else {
                jobs[jobs.count - 1].append(word)
            }
        }
        for job in jobs { run(job, rep) }
    }

    static func run(_ job: [String], _ rep: NSBitmapImageRep) {
        let numbers = job.dropFirst().compactMap { Int($0) }
        switch job[0] {
        case "column", "row":
            guard numbers.count == 3 else { return }
            var runs: [(String, Int, Int)] = []
            for step in numbers[1]..<numbers[2] {
                let colour = job[0] == "column" ? hex(rep, numbers[0], step) : hex(rep, step, numbers[0])
                if let last = runs.last, last.0 == colour {
                    runs[runs.count - 1].2 += 1
                } else {
                    runs.append((colour, step, 1))
                }
            }
            print(runs.map { "\($0.1):\($0.0)x\($0.2)" }.joined(separator: " "))
        case "box":
            guard numbers.count == 4 else { return }
            var counts: [String: Int] = [:]
            for y in numbers[1]..<(numbers[1] + numbers[3]) {
                for x in numbers[0]..<(numbers[0] + numbers[2]) { counts[hex(rep, x, y), default: 0] += 1 }
            }
            let total = max(1, counts.values.reduce(0, +))
            let top = counts.sorted { $0.value > $1.value }.prefix(4)
            print(top.map { "\($0.key) \(String(format: "%.3f", Double($0.value) / Double(total)))" }.joined(separator: ", "), "kinds \(counts.count)")
        case "foot":
            guard numbers.count == 2 else { return }
            var pixel = [Int](repeating: 0, count: 4)
            func grey(_ x: Int, _ y: Int) -> [Int] {
                rep.getPixel(&pixel, atX: x, y: y)
                return Array(pixel.prefix(3))
            }
            let floor = rep.pixelsHigh - 3
            let ground = grey((numbers[0] + numbers[1]) / 2, floor)
            var found = -1
            var y = floor
            while y >= 0, found < 0 {
                for x in numbers[0]..<numbers[1] {
                    let here = grey(x, y)
                    if zip(here, ground).contains(where: { abs($0 - $1) > 2 }) {
                        found = y
                        break
                    }
                }
                y -= 1
            }
            print("\(found) \(rep.pixelsHigh - 1 - found)")
        case "crop":
            guard numbers.count >= 5, let out = job.last, let image = rep.cgImage,
                  let cut = image.cropping(to: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])) else { return }
            let scale = numbers[4]
            let space = cut.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(data: nil, width: cut.width * scale, height: cut.height * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .none
            context.draw(cut, in: CGRect(x: 0, y: 0, width: cut.width * scale, height: cut.height * scale))
            guard let made = context.makeImage() else { return }
            try? NSBitmapImageRep(cgImage: made).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            print("crop \(made.width)x\(made.height)")
        default:
            break
        }
    }
}
