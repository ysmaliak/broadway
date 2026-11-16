import AppKit

struct GroundInk: Equatable {
    var dark: Bool
    var lift: Double = 0
    var stops: [Oklch]? = nil

    var appearance: NSAppearance? { NSAppearance(named: dark ? .darkAqua : .aqua) }
    var kit: KitInk { KitInk(lift: lift) }

    static func plain(dark: Bool) -> GroundInk { GroundInk(dark: dark) }

    static func on(_ look: SpaceLook, ground dark: Bool) -> GroundInk {
        GroundInk(dark: look.inkLight(dark: dark), lift: look.inkLift(dark: dark), stops: look.ground(dark: dark).stops)
    }

    static func on(_ blend: LookBlend, ground dark: Bool) -> GroundInk {
        GroundInk(dark: blend.inkLight(dark: dark), lift: blend.inkLift(dark: dark), stops: blend.groundStops(dark: dark))
    }
}

extension NSView {
    func wear(_ ink: GroundInk) {
        let wanted = ink.appearance
        if appearance?.name != wanted?.name { appearance = wanted }
    }
}
