import AppKit

func pixels(_ path: String) -> (width: Int, height: Int, data: [UInt8])? {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let width = cg.width, height = cg.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (width, height, data)
}

@main struct Run {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 4 else {
            print("usage: pixeldiff before.png after.png diff.png [channel=16] [share=0.005]")
            exit(2)
        }
        let channel = args.count > 4 ? Int(args[4]) ?? 16 : 16
        let share = args.count > 5 ? Double(args[5]) ?? 0.005 : 0.005
        guard let a = pixels(args[1]), let b = pixels(args[2]) else {
            print(#"{"error": "unreadable image", "pass": false}"#)
            exit(1)
        }
        guard a.width == b.width, a.height == b.height else {
            print(#"{"error": "size \#(a.width)x\#(a.height) against \#(b.width)x\#(b.height)", "pass": false}"#)
            exit(1)
        }
        var out = [UInt8](repeating: 0, count: a.data.count)
        var differing = 0, touched = 0, largest = 0
        for i in stride(from: 0, to: a.data.count, by: 4) {
            var delta = 0
            for c in 0..<4 { delta = max(delta, abs(Int(a.data[i + c]) - Int(b.data[i + c]))) }
            largest = max(largest, delta)
            if delta > 0 { touched += 1 }
            let grey = UInt8((Int(a.data[i]) + Int(a.data[i + 1]) + Int(a.data[i + 2])) / 12 + 160)
            if delta > channel {
                differing += 1
                out[i] = 255; out[i + 1] = 0; out[i + 2] = 64; out[i + 3] = 255
            } else if delta > 0 {
                out[i] = 255; out[i + 1] = 190; out[i + 2] = 0; out[i + 3] = 255
            } else {
                out[i] = grey; out[i + 1] = grey; out[i + 2] = grey; out[i + 3] = 255
            }
        }
        let total = a.width * a.height
        let fraction = Double(differing) / Double(max(total, 1))
        let pass = fraction <= share
        if let context = CGContext(data: &out, width: a.width, height: a.height, bitsPerComponent: 8, bytesPerRow: a.width * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let image = context.makeImage() {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[3]))
        }
        print(#"{"width": \#(a.width), "height": \#(a.height), "touched": \#(touched), "differing": \#(differing), "share": \#(fraction), "max": \#(largest), "channel": \#(channel), "allowed": \#(share), "pass": \#(pass)}"#)
        exit(pass ? 0 : 1)
    }
}
