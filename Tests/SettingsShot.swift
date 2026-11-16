import AppKit
import ScreenCaptureKit

@main struct Run {
    static func main() async throws {
        guard CGPreflightScreenCaptureAccess() else { print("SKIP: screen recording permission unavailable"); return }
        let args = CommandLine.arguments
        let pid = Int32(args[1])!
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let mine = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
        if args[2] == "list" {
            for window in mine {
                print("\(window.windowID)\t\(Int(window.frame.width))x\(Int(window.frame.height))\t\(window.title ?? "")")
            }
            return
        }
        let number = UInt32(args[2])!
        let out = URL(fileURLWithPath: args[3])
        guard let window = mine.first(where: { $0.windowID == number }) else { print("SKIP: no test window"); return }
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
