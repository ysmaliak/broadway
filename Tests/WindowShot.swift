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
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                               configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])!.write(to: out)
        print("shot \(out.lastPathComponent) \(image.width)x\(image.height)")
    }
}
