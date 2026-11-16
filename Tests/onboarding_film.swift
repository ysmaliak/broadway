import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class Take: NSObject, SCStreamOutput, SCRecordingOutputDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "onboarding-film")
    var times: [Double] = []
    var first: Double?

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue else { return }
        let time = buffer.presentationTimeStamp.seconds
        if first == nil { first = time }
        times.append(time - (first ?? time))
    }
}

@main struct Run {
    static func main() async throws {
        _ = NSApplication.shared
        guard CGPreflightScreenCaptureAccess() else { print("SKIP: screen recording permission unavailable"); return }
        let args = CommandLine.arguments
        guard args.count >= 6 else {
            print("usage: onboarding_film window PID NUMBER | display INDEX 0, then OUT.mp4 SECONDS [FPS] [SCALE]")
            return
        }
        let mode = args[1]
        let out = URL(fileURLWithPath: args[4])
        let seconds = Double(args[5]) ?? 5
        let fps = args.count > 6 ? Int32(args[6]) ?? 60 : 60
        let scale = args.count > 7 ? Double(args[7]) ?? 1 : 1
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let filter: SCContentFilter
        let size: CGSize
        if mode == "display" {
            let index = Int(args[2]) ?? 0
            let screens = NSScreen.screens
            guard screens.indices.contains(index),
                  let id = screens[index].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { print("SKIP: no display"); return }
            filter = SCContentFilter(display: display, excludingWindows: [])
            size = CGSize(width: display.width, height: display.height)
        } else {
            let pid = Int32(args[2]) ?? 0
            let number = UInt32(args[3]) ?? 0
            guard let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.windowID == number }) else {
                print("SKIP: no window"); return
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = window.frame.size
        }
        let config = SCStreamConfiguration()
        config.width = Int(size.width * scale) / 2 * 2
        config.height = Int(size.height * scale) / 2 * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.queueDepth = 8
        let take = Take()
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(take, type: .screen, sampleHandlerQueue: take.queue)
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = out
        recording.outputFileType = .mp4
        recording.videoCodecType = .h264
        try stream.addRecordingOutput(SCRecordingOutput(configuration: recording, delegate: take))
        try await stream.startCapture()
        print("ready")
        fflush(stdout)
        try await Task.sleep(for: .seconds(seconds))
        try? await stream.stopCapture()
        let times = take.queue.sync { take.times }
        var gaps: [Double] = []
        for index in 1..<max(times.count, 1) { gaps.append((times[index] - times[index - 1]) * 1000) }
        let report: [String: Any] = ["times": times, "gaps": gaps, "width": config.width, "height": config.height, "fps": fps]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        try json.write(to: out.deletingPathExtension().appendingPathExtension("json"))
        print("filmed \(times.count) frames")
    }
}
