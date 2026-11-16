import AppKit
import ScreenCaptureKit

@main struct Run {
    static func main() async throws {
        guard CGPreflightScreenCaptureAccess() else { print("SKIP: screen recording permission unavailable"); return }
        let args = CommandLine.arguments
        let pid = Int32(args[1])!
        let numbers = args[2].split(separator: ",").compactMap { UInt32($0) }
        let out = URL(fileURLWithPath: args[3])
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let windows = numbers.compactMap { number in
            content.windows.first { $0.owningApplication?.processID == pid && $0.windowID == number }
        }
        guard windows.count == numbers.count, let first = windows.first else { print("SKIP: no test window"); return }
        guard let display = content.displays.first(where: { $0.frame.intersects(first.frame) }) ?? content.displays.first else {
            print("SKIP: no display"); return
        }
        let asked = args.count > 4 ? args[4].split(separator: ",").compactMap { Double($0) } : []
        let framing: CGRect? = asked.count == 4 ? CGRect(x: asked[0], y: asked[1], width: asked[2], height: asked[3])
            : args.count > 4 ? UInt32(args[4]).flatMap { number in
                content.windows.first { $0.owningApplication?.processID == pid && $0.windowID == number }?.frame
            } : nil
        let bounds = framing ?? windows.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let source = bounds.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = Int(source.width * scale)
        config.height = Int(source.height * scale)
        config.showsCursor = false
        config.backgroundColor = .clear
        let filter = SCContentFilter(display: display, including: windows)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])!.write(to: out)
        print("shot \(out.lastPathComponent) \(image.width)x\(image.height) at \(bounds.minX),\(bounds.minY),\(bounds.width),\(bounds.height)")
    }
}
