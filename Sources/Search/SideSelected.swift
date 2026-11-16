import AppKit
import QuartzCore

enum SelectedLook {
    static var unclipped = false
    static let shadow = SideLook.selectedShadow
    static var room: CGFloat { reach(shadow) }

    static func reach(_ shadow: KitShadow) -> CGFloat {
        (shadow.radius * 1.5 + abs(shadow.y) + 0.5).rounded(.up)
    }

    @MainActor static func dress(_ plate: KitPlate, greys: KitGreys, ink: KitInk, picked: Bool = false, lifts: Bool = true) {
        plate.ink = ink
        plate.fill = greys.well
        plate.foot = nil
        plate.stroke = greys.onFrame ? nil : picked ? nil : greys.slabEdge
        plate.hairline = true
        plate.rim = nil
        plate.ramp = nil
        plate.lift = lifts ? shadow : nil
    }

    @MainActor static func cast(on layer: CALayer, dark: Bool, path: CGPath) {
        let opacity = dark ? shadow.dark : shadow.light
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = shadow.radius
        layer.shadowOffset = CGSize(width: 0, height: shadow.y)
        layer.shadowPath = opacity > 0 ? path : nil
    }

    @MainActor static func unclip(_ on: Bool, in root: NSView) {
        unclipped = on
        func walk(_ view: NSView) {
            if let page = view as? SidePageView { page.reclip() }
            if let column = view as? SideColumnView { column.clipsToBounds = !on }
            view.subviews.forEach(walk)
        }
        walk(root)
    }
}
