import AppKit

@main struct Run {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 6, let data = FileManager.default.contents(atPath: args[1]), let rep = NSBitmapImageRep(data: data) else {
            print("{}")
            return
        }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let fx = [Double(args[2])!, Double(args[4])!].map { Int($0 * Double(w)) }
        let fy = [Double(args[3])!, Double(args[5])!].map { Int($0 * Double(h)) }
        var counts: [UInt32: Int] = [:]
        var sum = (0.0, 0.0, 0.0)
        var n = 0
        var pixel = [Int](repeating: 0, count: 4)
        for y in stride(from: max(0, fy[0]), to: min(h, fy[1]), by: 2) {
            for x in stride(from: max(0, fx[0]), to: min(w, fx[1]), by: 2) {
                rep.getPixel(&pixel, atX: x, y: y)
                counts[UInt32(pixel[0]) << 16 | UInt32(pixel[1]) << 8 | UInt32(pixel[2]), default: 0] += 1
                sum.0 += Double(pixel[0])
                sum.1 += Double(pixel[1])
                sum.2 += Double(pixel[2])
                n += 1
            }
        }
        let mode = counts.max { $0.value < $1.value }!
        let share = Double(mode.value) / Double(max(1, n))
        let mean = [sum.0, sum.1, sum.2].map { String(format: "%.1f", $0 / Double(max(1, n))) }.joined(separator: ",")
        print("{\"mode\": \"\(String(format: "%06X", mode.key))\", \"modeShare\": \(String(format: "%.3f", share)), \"mean\": [\(mean)]}")
    }
}
