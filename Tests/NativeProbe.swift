import AppKit
import CoreGraphics

switch CommandLine.arguments.dropFirst().first {
case "keycode":
    let character = CommandLine.arguments[2]
    let code = (0..<51).first { key in
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: 0, context: nil, characters: "x",
                                    charactersIgnoringModifiers: "x", isARepeat: false, keyCode: UInt16(key))
        return event?.characters(byApplyingModifiers: []) == character
    }
    print(code ?? -1)
case "windows":
    let pids = Set(CommandLine.arguments.dropFirst(2).compactMap(Int.init))
    guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
        fatalError("Window list is unavailable")
    }
    print(windows.filter { pids.contains($0[kCGWindowOwnerPID as String] as? Int ?? -1) }.count)
default:
    fatalError("Expected keycode or windows")
}
