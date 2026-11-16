import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: film_strip FRAMES_DIR OUT.png MARKS [COLUMNS] [WIDTH] [CROP x,y,w,h unit]\n".data(using: .utf8)!)
    exit(2)
}
let folder = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])
var marks: [Int: String] = [:]
for part in args[3].split(separator: ",") where !part.isEmpty {
    let pair = part.split(separator: ":", maxSplits: 1)
    if let index = Int(pair[0]) { marks[index] = pair.count > 1 ? String(pair[1]) : "bad" }
}
let columns = args.count > 4 ? Int(args[4]) ?? 8 : 8
let cellWidth = args.count > 5 ? CGFloat(Double(args[5]) ?? 300) : 300
let crop: CGRect? = args.count > 6 ? {
    let n = args[6].split(separator: ",").compactMap { Double($0) }
    return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : nil
}() : nil

let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "png" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
let pictures: [(Int, CGImage)] = files.compactMap { url in
    guard let index = Int(url.deletingPathExtension().lastPathComponent),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let whole = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    guard let crop else { return (index, whole) }
    let w = CGFloat(whole.width), h = CGFloat(whole.height)
    let rect = CGRect(x: crop.minX * w, y: crop.minY * h, width: crop.width * w, height: crop.height * h).integral
    return whole.cropping(to: rect).map { (index, $0) }
}
guard let first = pictures.first?.1 else { exit(1) }
let cellHeight = (cellWidth * CGFloat(first.height) / CGFloat(first.width)).rounded()
let label: CGFloat = 18
let gap: CGFloat = 6
let rows = (pictures.count + columns - 1) / columns
let width = Int(CGFloat(columns) * (cellWidth + gap) + gap)
let height = Int(CGFloat(rows) * (cellHeight + label + gap) + gap)
guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { exit(1) }
context.setFillColor(CGColor(gray: 0.12, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
for (position, (index, image)) in pictures.enumerated() {
    let column = position % columns
    let row = position / columns
    let x = gap + CGFloat(column) * (cellWidth + gap)
    let y = CGFloat(height) - CGFloat(row + 1) * (cellHeight + label + gap)
    let rect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
    context.interpolationQuality = .high
    context.draw(image, in: rect)
    let mark = marks[index]
    if mark != nil {
        context.setStrokeColor(CGColor(red: 1, green: 0.15, blue: 0.1, alpha: 1))
        context.setLineWidth(4)
        context.stroke(rect.insetBy(dx: 2, dy: 2))
    }
    let text = NSAttributedString(string: mark.map { "\(index)  \($0)" } ?? "\(index)", attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: mark == nil ? NSColor.white : NSColor(red: 1, green: 0.35, blue: 0.3, alpha: 1),
    ])
    text.draw(at: NSPoint(x: x + 2, y: y + cellHeight + 2))
}
NSGraphicsContext.restoreGraphicsState()
guard let made = context.makeImage(),
      let target = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(target, made, nil)
exit(CGImageDestinationFinalize(target) ? 0 : 1)
