import AppKit
import ScreenCaptureKit

@main struct Run {
    static func shot(_ window: SCWindow, scale: CGFloat) async throws -> CGImage {
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                          configuration: config)
    }

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
        guard let parent = mine.first(where: { $0.windowID == UInt32(args[2]) }),
              let sheet = mine.first(where: { $0.windowID == UInt32(args[3]) }) else { print("SKIP: no test window"); return }
        let out = URL(fileURLWithPath: args[4])
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let under = try await shot(parent, scale: scale)
        let over = try await shot(sheet, scale: scale)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: under.width, height: under.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(under, in: CGRect(x: 0, y: 0, width: under.width, height: under.height))
        let left = (sheet.frame.minX - parent.frame.minX) * scale
        let top = (sheet.frame.minY - parent.frame.minY) * scale
        context.draw(over, in: CGRect(x: left, y: CGFloat(under.height) - top - CGFloat(over.height),
                                      width: CGFloat(over.width), height: CGFloat(over.height)))
        guard let image = context.makeImage() else { return }
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: out)
        print("shot \(out.lastPathComponent) \(image.width)x\(image.height) sheet at \(Int(left / scale)),\(Int(top / scale))")
    }
}
