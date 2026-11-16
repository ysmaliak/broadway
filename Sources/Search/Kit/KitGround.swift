import AppKit

@MainActor
enum KitGround {
    static func ink(_ browser: Browser, on: Bool, dark base: Bool) -> (dark: Bool, ink: KitInk) {
        guard on else { return (base, .flat) }
        let here = browser.seenLook
        let next = browser.spaceNext.flatMap { browser.spaces.indices.contains($0) ? browser.spaces[$0].look ?? SpaceLook() : SpaceLook() }
        let blend = LookBlend(from: here, to: next, share: next != nil && browser.spaceMotion.crossing.past ? 1 : 0)
        return (blend.inkLight(dark: base), KitInk(lift: blend.inkLift(dark: base)))
    }

    static func appearance(dark: Bool) -> NSAppearance? {
        NSAppearance(named: dark ? .darkAqua : .aqua)
    }
}
