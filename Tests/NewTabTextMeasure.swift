import AppKit

@main struct Run {
    static func main() {
        let args = CommandLine.arguments
        guard let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: args[1]))) else { exit(1) }
        let n = args[2...].compactMap { Double($0) }
        let k = Double(rep.pixelsWide) / n[0]
        let field = Array(n[1...4]), boxes = stride(from: 5, to: n.count, by: 4).map { Array(n[$0..<$0 + 4]) }
        func rgb(_ x: Int, _ y: Int) -> [Double] {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return [0, 0, 0] }
            return [c.redComponent, c.greenComponent, c.blueComponent]
        }
        let fill = rgb(Int((field[0] + field[2] - 40) * k), Int((field[1] + field[3] / 2) * k))
        let top = Int((field[1] + 6) * k), bottom = Int((field[1] + field[3] - 6) * k)
        let bands = boxes.map { box -> String in
            guard box[2] > 0 else { return "null" }
            var first: Int?, last: Int?
            for y in top..<bottom {
                let inked = (Int(box[0] * k)..<Int((box[0] + box[2]) * k)).contains { x in
                    zip(rgb(x, y), fill).map { abs($0 - $1) }.reduce(0, +) > 0.35
                }
                if inked { first = first ?? y; last = y }
            }
            guard let first, let last else { return "null" }
            return "[\(Double(first) / k), \(Double(last + 1) / k)]"
        }
        print("{\"mid\": \(field[1] + field[3] / 2), \"bands\": [\(bands.joined(separator: ", "))]}")
    }
}
