import AppKit
import AVFoundation
import ScreenCaptureKit

final class Watch: NSObject, SCRecordingOutputDelegate {}

@main struct Run {
    static func main() async throws {
        guard CGPreflightScreenCaptureAccess() else { print("SKIP: screen recording permission unavailable"); return }
        let args = CommandLine.arguments
        guard args.count >= 5, let pid = Int32(args[1]), let number = UInt32(args[2]), let seconds = Double(args[4]) else {
            print("usage: SettingsFilm PID WINDOW OUT.mp4 SECONDS")
            return
        }
        let out = URL(fileURLWithPath: args[3])
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.windowID == number }) else {
            print("SKIP: no test window")
            return
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: nil)
        try? FileManager.default.removeItem(at: out)
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = out
        recording.outputFileType = .mp4
        let watch = Watch()
        try stream.addRecordingOutput(SCRecordingOutput(configuration: recording, delegate: watch))
        try await stream.startCapture()
        print("filming")
        fflush(stdout)
        try await Task.sleep(for: .seconds(seconds))
        try await stream.stopCapture()
        print("film \(out.lastPathComponent)")
    }
}
