import AppKit
import QuartzCore
import SwiftUI

final class Shown: ObservableObject { @Published var far = false }

struct Moving: View {
    @ObservedObject var shown: Shown
    var body: some View {
        ZStack(alignment: .leading) {
            Color.black
            Rectangle().fill(.red).frame(width: 40, height: 40).offset(x: shown.far ? 340 : 0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let mode = CommandLine.arguments.dropFirst().first ?? "ca"
let screen = NSScreen.screens.max { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond } ?? NSScreen.main!
let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
let shown = Shown()
let box = NSView(frame: NSRect(x: 0, y: 100, width: 40, height: 40))
box.wantsLayer = true
box.layer?.backgroundColor = NSColor.red.cgColor
if mode.hasPrefix("swiftui") {
    window.contentView = NSHostingView(rootView: Moving(shown: shown))
} else {
    let ground = NSView()
    ground.wantsLayer = true
    ground.layer?.backgroundColor = NSColor.black.cgColor
    ground.addSubview(box)
    window.contentView = ground
}
window.orderFrontRegardless()
let wide = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 400 : 400
let high = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 300 : 300
window.setFrame(NSRect(x: screen.visibleFrame.midX - wide / 2, y: screen.visibleFrame.midY - high / 2, width: wide, height: high), display: true)
print("ready \(screen.maximumFramesPerSecond)")
fflush(stdout)
func go() {
    if mode == "swiftui" || mode == "swiftui-block" {
        if mode == "swiftui-block" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Thread.sleep(forTimeInterval: 0.3) } }
        withAnimation(.spring(response: 0.6, dampingFraction: 1)) { shown.far = true }
    } else {
        let move = CASpringAnimation(keyPath: "position.x")
        move.fromValue = 20
        move.toValue = 360
        move.mass = 1
        move.stiffness = pow(2 * .pi / 0.6, 2)
        move.damping = 4 * .pi / 0.6
        move.duration = move.settlingDuration
        if mode == "ca" { move.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120) }
        box.layer?.position.x = 360
        box.layer?.add(move, forKey: "move")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { exit(0) }
}
if CommandLine.arguments.contains("--wait") {
    Thread.detachNewThread {
        _ = readLine()
        DispatchQueue.main.async { go() }
    }
} else {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { go() }
}
app.run()
