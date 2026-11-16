import AppKit
import ScreenCaptureKit

@MainActor
func captureFileChoice() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    _ = NSScreen.screens
    guard CGPreflightScreenCaptureAccess() else { print("Screen capture permission unavailable; no prompt requested"); exit(2) }
    let args = CommandLine.arguments
    guard args.count == 6, let pid = Int32(args[1]), let id = UInt32(args[2]),
          let width = Int(args[3]), let height = Int(args[4]) else { exit(1) }
    try await Task.sleep(for: .milliseconds(800))
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let target = content.windows.first(where: { $0.windowID == id && $0.owningApplication?.processID == pid }) else {
        print("Test window unavailable")
        exit(1)
    }
    let filter = SCContentFilter(desktopIndependentWindow: target)
    let config = SCStreamConfiguration()
    config.width = width
    config.height = height
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: URL(fileURLWithPath: args[5]))
    print("Captured test picker window")
}

Task { @MainActor in
    do { try await captureFileChoice(); exit(0) }
    catch { print(error); exit(1) }
}
RunLoop.main.run()
