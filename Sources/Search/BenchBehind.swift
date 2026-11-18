import AppKit

extension NSWindow.Level {
    static let benchBehind = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
}

extension NSWindow {
    func benchShowBehind() {
        if level.rawValue > NSWindow.Level.benchBehind.rawValue { level = .benchBehind }
        orderBack(nil)
    }
}
