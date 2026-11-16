import AppKit
import ScreenCaptureKit

@main struct Run {
    static func main() async throws {
        guard CGPreflightScreenCaptureAccess() else { print("SKIP: screen recording permission unavailable"); return }
        let args = CommandLine.arguments
        let pid = Int32(args[1])!
        let number = UInt32(args[2])!
        let out = URL(fileURLWithPath: args[3])
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.windowID == number }) else {
            print("SKIP: no test window"); return
        }
        let centre = CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(centre) }) ?? content.displays.first else {
            print("SKIP: no display"); return
        }
        let desk = content.windows.filter { $0.windowLayer < 0 && $0.isOnScreen }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let filter = SCContentFilter(display: display, including: desk + [window])
        let config = SCStreamConfiguration()
        config.sourceRect = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])!.write(to: out)
        print("shot \(out.lastPathComponent) \(image.width)x\(image.height) desk \(desk.count) onScreen \(window.isOnScreen)")
    }
}
