import CoreGraphics
import Foundation

@main
struct WindowList {
    static func screens() -> [[Double]] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map { id in
            let bounds = CGDisplayBounds(id)
            return [bounds.minX, bounds.minY, bounds.width, bounds.height]
        }
    }

    static func windows(of pid: Int32) -> [[String: Any]] {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.map { row in
            let bounds = row[kCGWindowBounds as String] as? [String: Double] ?? [:]
            return ["number": row[kCGWindowNumber as String] as? Int ?? 0,
                    "onscreen": row[kCGWindowIsOnscreen as String] as? Bool ?? false,
                    "layer": row[kCGWindowLayer as String] as? Int ?? 0,
                    "alpha": row[kCGWindowAlpha as String] as? Double ?? 1,
                    "bounds": [bounds["X"] ?? 0, bounds["Y"] ?? 0, bounds["Width"] ?? 0, bounds["Height"] ?? 0]]
        }
    }

    static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    static func sample(pid: Int32, every: Double) {
        while true {
            emit(["time": Date().timeIntervalSince1970, "screens": screens(), "windows": windows(of: pid)])
            Thread.sleep(forTimeInterval: every)
        }
    }

    static func shift(seconds: Double) {
        let display = CGMainDisplayID()
        guard let current = CGDisplayCopyDisplayMode(display),
              let modes = CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode] else {
            emit(["changed": false, "reason": "no display modes"])
            return
        }
        guard let other = modes.first(where: { $0.width != current.width && $0.isUsableForDesktopGUI() }) else {
            emit(["changed": false, "reason": "no other mode"])
            return
        }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayWithDisplayMode(config, display, other, nil)
        let done = CGCompleteDisplayConfiguration(config, .forAppOnly)
        emit(["changed": done == .success, "from": [current.width, current.height], "to": [other.width, other.height]])
        Thread.sleep(forTimeInterval: seconds)
    }

    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count >= 3, arguments[1] == "shift", let seconds = Double(arguments[2]) {
            shift(seconds: seconds)
            return
        }
        guard arguments.count >= 2, let pid = Int32(arguments[1]) else {
            FileHandle.standardError.write(Data("usage: WindowList PID [EVERY] | shift SECONDS\n".utf8))
            exit(2)
        }
        sample(pid: pid, every: arguments.count >= 3 ? Double(arguments[2]) ?? 0.1 : 0.1)
    }
}
