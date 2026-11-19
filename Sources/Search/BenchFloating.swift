import AppKit

@MainActor
enum BenchFloating {
    static let names = ["float-feedback", "float-controls", "mini-player", "call-bar", "escape-reminder", "reload-door",
                        "agent-character", "agent-pointer", "link-bubble", "at-rest", "driving-bar", "passkey-switch"]

    static func make(_ name: String, _ request: [String: Any]) -> NSView? {
        let lift = request["lift"] as? Double ?? 0
        let frame = request["frame"] as? Bool ?? false
        switch name {
        case "float-feedback":
            return FloatSurfaces.feedback(request["text"] as? String ?? "1.5×")
        case "float-controls":
            return Float.surface(request)
        case "mini-player":
            return MiniPlayer.surface(lift: lift, frame: frame, playing: request["playing"] as? Bool ?? false,
                                      pair: MiniPair(rawValue: request["pair"] as? String ?? "") ?? .tracks)
        case "call-bar":
            return CallFloat.surface(mic: request["mic"] as? Bool ?? true, camera: request["camera"] as? Bool ?? false,
                                     leaves: request["leaves"] as? Bool ?? true)
        case "escape-reminder":
            return FullScreenEscape.surface()
        case "reload-door":
            return ReloadFace.surface(stop: request["stop"] as? Bool ?? false, lift: lift, frame: frame)
        case "agent-character":
            return request["sheet"] as? Bool == true ? AgentCharacter.sheet(lift: lift) : AgentCharacter.surface(lift: lift)
        case "agent-pointer":
            return AgentPointers.surface(kind: AgentPointer.Kind(rawValue: request["kind"] as? String ?? "type") ?? .type)
        case "link-bubble":
            return LinkStatus.surface(request["address"] as? String ?? "https://developer.apple.com/documentation/appkit/nsglasseffectview")
        case "at-rest":
            return AtRest.surface(lift: lift)
        case "driving-bar":
            return AgentDriving.surface()
        case "passkey-switch":
            return PasskeyStatus.surface(broadway: request["broadway"] as? Bool ?? true)
        default:
            return nil
        }
    }

    static func sized(_ view: NSView, _ size: NSSize) -> NSView {
        let box = SizedSurface(size: size)
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        box.addSubview(view)
        return box
    }
}

private final class SizedSurface: NSView {
    let size: NSSize

    init(size: NSSize) {
        self.size = size
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { size }
    override var fittingSize: NSSize { size }
}
