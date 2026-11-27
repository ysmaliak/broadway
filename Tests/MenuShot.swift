import AppKit
import ScreenCaptureKit

@main struct Run {
    static func main() async throws {
        guard CGPreflightScreenCaptureAccess() else { print("SKIP: screen recording permission unavailable"); return }
        let args = CommandLine.arguments
        let pid = Int32(args[1])!
        let number = UInt32(args[2])!
        let out = URL(fileURLWithPath: args[3])
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let owned = content.windows.filter { $0.owningApplication?.processID == pid && $0.isOnScreen && $0.frame.width > 2 }
        guard let main = owned.first(where: { $0.windowID == number }) else { print("SKIP: no test window"); return }
        guard let display = content.displays.first(where: { $0.frame.intersects(main.frame) }) ?? content.displays.first else {
            print("SKIP: no display"); return
        }
        let windows = owned.filter { $0.windowID == number || $0.frame.intersects(display.frame) }
        let union = windows.reduce(main.frame) { $0.union($1.frame) }
        let area = union.intersection(display.frame)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: area.minX - display.frame.minX, y: area.minY - display.frame.minY, width: area.width, height: area.height)
        config.width = Int(area.width * scale)
        config.height = Int(area.height * scale)
        config.showsCursor = false
        config.backgroundColor = .clear
        let filter = SCContentFilter(display: display, including: windows)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])!.write(to: out)
        let menus = windows.filter { $0.windowLayer >= Int(CGWindowLevelForKey(.popUpMenuWindow)) }.count
        print("shot \(out.lastPathComponent) \(image.width)x\(image.height) windows \(windows.count) menus \(menus) scale \(scale)")
    }
}
