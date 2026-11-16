import AppKit

@main
enum LightsCrop {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 8, let image = NSImage(contentsOfFile: args[1]),
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let x = Double(args[3]), let y = Double(args[4]), let w = Double(args[5]), let h = Double(args[6]),
              let scale = Double(args[7]) else {
            print("usage: LightsCrop PNG OUT X Y W H SCALE [PX,PY ...]")
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: source)
        var samples: [[Int]] = []
        for point in args.dropFirst(8) {
            let parts = point.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            let cx = Int(parts[0] * scale), cy = Int(parts[1] * scale)
            var sum = [0.0, 0.0, 0.0]
            var count = 0.0
            for dx in -1...1 {
                for dy in -1...1 {
                    guard let colour = rep.colorAt(x: cx + dx, y: cy + dy)?.usingColorSpace(.sRGB) else { continue }
                    sum[0] += colour.redComponent * 255
                    sum[1] += colour.greenComponent * 255
                    sum[2] += colour.blueComponent * 255
                    count += 1
                }
            }
            samples.append(sum.map { Int(($0 / max(count, 1)).rounded()) })
        }
        let cut = CGRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale)
        guard let piece = source.cropping(to: cut) else { print("no crop"); exit(1) }
        let width = Int(w * 3), height = Int(h * 3)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
        context.interpolationQuality = .none
        context.draw(piece, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let big = context.makeImage() else { exit(1) }
        try? NSBitmapImageRep(cgImage: big).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
        let line = samples.map { "rgb(\($0[0]),\($0[1]),\($0[2]))" }.joined(separator: " ")
        print(line)
    }
}
