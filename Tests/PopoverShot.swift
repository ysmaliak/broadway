import AppKit
import ScreenCaptureKit

@main struct Run {
    static func main() async throws {
        guard CGPreflightScreenCaptureAccess() else { print("SKIP: screen recording permission unavailable"); return }
        let args = CommandLine.arguments
        let pid = Int32(args[1])!
        let main = UInt32(args[2])!
        let out = URL(fileURLWithPath: args[3])
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowID != main && $0.frame.width > 200 && $0.frame.width < 600 && $0.frame.height > 200
        }
        guard let window = candidates.max(by: { $0.frame.height < $1.frame.height }) else { print("SKIP: no popover"); return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                               configuration: config)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: out)
        print("shot \(out.lastPathComponent) \(image.width)x\(image.height)")
    }
}
