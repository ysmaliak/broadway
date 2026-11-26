import AppKit

enum Palette {
    enum NS {
        static let ground = pair(1.0, 0.22)
        static let fieldPanel = pair(0.985, 0.23)
        static let fieldPick = pair(0.91, 0.30)
        static let fieldPlate = over(0, 0.07, 1.0, 0.10)
        static let keycap = pair(0.86, 0.36)
        static let glassTint = over(1.0, 0.55, 0.1, 0.6)
        static let glassGround = over(1.0, 0.86, 0.22, 0.92)
        static let glassMuted = inked(0.72, 0.78)
        static let glassFaint = inked(0.66, 0.68)
        static let glassAlert = tint(light: (0.76, 0.10, 0.09), dark: (1.0, 0.76, 0.73))
        static let glassSafe = tint(light: (0.07, 0.45, 0.21), dark: (0.29, 0.87, 0.50))
        static let ink = pair(0.09, 0.93)
        static let inkStrong = pair(0.09, 1.0)
        static let muted = inked(0.4945, 0.507)
        static let faint = inked(0.187, 0.282)
        static let hairline = inked(0.099, 0.113)
        static let pickedPlate = inked(0.08, 0.12)
        static let pictureEdge = inked(0.05, 0.07)
        static let wash = pair(0.937, 0.30)
        static let pinLive = pair(0.90, 0.34)
        static let hover = pair(0.965, 0.265)
        static let picked = pair(0.952, 0.272)
        static let frame = pair(0.925, 0.19)
        static let sideWash = over(1.0, 1.0, 1.0, 0.14)
        static let sideHover = over(0, 0.035, 1.0, 0.05)
        static let sidePicked = over(1.0, 0.7, 1.0, 0.1)
        static let sideSlabEdge = over(0, 0.14, 1.0, 0.21)
        static let sideWell = over(1.0, 1.0, 1.0, 0.12)
        static let sideWellRim = over(0, 0, 1.0, 0.20)
        static let sideRule = over(0, 0.07, 1.0, 0.095)
        static let sideTile = over(0, 0.03, 1.0, 0.05)
        static let sidePinLive = over(1.0, 0.5, 1.0, 0.11)
        static let sideEdge = over(0, 0.07, 1.0, 0.10)
        static let sideRaised = over(1.0, 0.55, 1.0, 0.10)
        static let sideTileEdge = over(0, 0, 1.0, 0)
        static let sideRaisedRim = over(0, 0.03, 1.0, 0.02)
        static let sideCard = over(1.0, 0.45, 1.0, 0.10)
        static let sideCardEdge = over(0, 0.09, 1.0, 0.15)
        static let raisedRim = over(0, 0.055, 1.0, 0.06)
        static let panelRaisedEdge = over(0, 0.07, 1.0, 0.12)
        static let cardEdge = over(0, 0.06, 1.0, 0.1)
        static let safe = tint(light: (0.08, 0.50, 0.24), dark: (0.29, 0.87, 0.50))
        static let unsafe = tint(light: (0.71, 0.33, 0.04), dark: (0.98, 0.75, 0.14))

        private static func tint(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
            NSColor(name: nil) { appearance in
                let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
            }
        }

        static let sideDot = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.88) : NSColor(white: 0.09, alpha: 0.82)
        }

        private static func inked(_ lightAlpha: CGFloat, _ darkAlpha: CGFloat) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(white: 0.93, alpha: darkAlpha) : NSColor(white: 0.09, alpha: lightAlpha)
            }
        }

        private static func over(_ light: CGFloat, _ lightAlpha: CGFloat, _ dark: CGFloat, _ darkAlpha: CGFloat) -> NSColor {
            NSColor(name: nil) { appearance in
                let dim = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(white: dim ? dark : light, alpha: dim ? darkAlpha : lightAlpha)
            }
        }

        private static func pair(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
            NSColor(name: nil) { appearance in
                let dim = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(white: dim ? dark : light, alpha: 1)
            }
        }
    }
}

enum Look: String, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }

    func apply() {
        let wanted = appearance
        DispatchQueue.main.async {
            guard NSApp.appearance !== wanted, NSApp.appearance?.name != wanted?.name else { return }
            NSApp.appearance = wanted
        }
    }
}

enum Metrics {
    static let strip: CGFloat = 52
    static let cardGap: CGFloat = 6
    static let pageRadius: CGFloat = 11
    static let floatGap: CGFloat = 4
    static let floatRadius: CGFloat = 12
    static let lights: CGFloat = 100
    static let helm: CGFloat = 4 * 30 + 3 * 4 + 8
    static let helmNarrow: CGFloat = 3 * 30 + 2 * 4 + 8
    static let helmLights: CGFloat = 78
    static let sideInset: CGFloat = 6
    static let sidePill: CGFloat = SideLook.pillHeight
    static let sideRadius: CGFloat = SideLook.rowRadius
    static let sideRowHeight: CGFloat = 34
    static let liveLine: CGFloat = SideLook.byline
    static let sideGap: CGFloat = 3
    static let sideDividerGap: CGFloat = 5
    static let folderAir: CGFloat = 3
    static let folderPad: CGFloat = SideLook.cardPad
    static let folderRadius: CGFloat = SideLook.cardRadius
    static let closeSide: CGFloat = 18

    static func closeSquare(_ height: CGFloat) -> CGFloat { max(18, min(34, height - 8)) }
    static func closeInset(_ height: CGFloat) -> CGFloat { max(0, (height - closeSquare(height)) / 2) }
    static func closeCorner(_ side: CGFloat) -> CGFloat { min(8, side * 0.27) }
    static let paneBar: CGFloat = 32
    static let pinRadius: CGFloat = SideLook.pinRadius
    static let bare: CGFloat = 34
    static let fieldWidth: CGFloat = 560
    static let side: CGFloat = 258
    static let sideMin: CGFloat = 200
    static let sideMax: CGFloat = 440
}

enum IconLook {
    static let weight = NSFont.Weight.medium
    static let control = NSFont.Weight.semibold
}

enum SideLook {
    static let rowRadius: CGFloat = 11
    static let cardRowRadius: CGFloat = cardRadius - cardPad
    static let cardPad: CGFloat = 3
    static let dropRing = 0.55
    static let dropRingWidth: CGFloat = 1.5
    static let fieldInset: CGFloat = 1
    static let fieldRadius: CGFloat = cardRadius - cardPad - fieldInset
    static let fieldLead: CGFloat = 3.5
    static let fieldWell = 0.45

    static func cardLift(dark: Bool) -> Double { dark ? 1.4 : 1.55 }
    static let growFade: CFTimeInterval = 0.2
    static let growLag: CFTimeInterval = 0.08
    static let headingFade: CFTimeInterval = 0.12
    static let shrinkLag: CFTimeInterval = 0.04
    static let foldLag: CFTimeInterval = 0.06
    static let cardRowInset: CGFloat = 16
    static let headingHeight: CGFloat = 28
    static let ruleInset: CGFloat = 5
    static let cardRadius: CGFloat = 14
    static let pinRadius: CGFloat = rowRadius
    static let pinMark: CGFloat = 16
    static let rowMark: CGFloat = 16
    static let pinsFoot: CGFloat = 8
    static let rowLead: CGFloat = 9
    static let markGap: CGFloat = 8
    static let titleLine: CGFloat = 16
    static let byline: CGFloat = 11
    static let bylineTone = 1.15
    static let bylineLine: CGFloat = 13
    static let headingWeight = NSFont.Weight.semibold
    static let headingName = 1.0
    static let headingMarkTone = 1.2
    static let chevron: CGFloat = 10
    static let chevronTone = 1.2
    static let chevronGap: CGFloat = 9
    static let chevronInline = true
    static let headingNameRoom: CGFloat = 70
    static let speakerRoom: CGFloat = rowMark + markGap
    static let speakerFrom: CGFloat = 0.6
    static let speakerLeave: TimeInterval = 0.14
    static let speakerHold: TimeInterval = 1.5
    static let selectedShadow = KitShadow(light: 0.07, dark: 0, radius: 1.5, y: 1)
    static let slabVivid = 0.6
    static let pillHeight: CGFloat = 34
    static let pillRadius: CGFloat = rowRadius
    static let pillLead: CGFloat = 12
    static let doorSize: CGFloat = 12
    static let doorWeight = IconLook.control
    static let siteIcon = "switch.2"
    static let pillFont = NSFont.systemFont(ofSize: 13)
    static let pillPress: CGFloat = 0.98
    static let pillFade: CGFloat = 18
}

enum TearLook {
    static let width: CGFloat = 220
    static let aspect: CGFloat = 10.0 / 16.0
    static let corner: CGFloat = 10
    static let grab = CGSize(width: 24, height: 16)
    static let fadeIn: CFTimeInterval = 0.10
    static let fadeOut: CFTimeInterval = 0.09
    static let fromScale: CGFloat = 0.90
    static let grow = KitSpring(response: 0.20, damping: 0.86)
    static let icon: CGFloat = 16
    static let pad: CGFloat = 12
    static let cardHeight: CGFloat = 64
    static let titleSize: CGFloat = 12
    static var shadow: KitShadow { PopupLook.shadow }
    static var edge: NSColor { PopupLook.edge }
    static var room: CGFloat { shadow.radius * 2 + shadow.y }
}

enum DockBarLook {
    static let tile: CGFloat = 128
    static let width: CGFloat = 96
    static let height: CGFloat = 10
    static let lift: CGFloat = 14
    static let inset: CGFloat = 1.5
    static let track = NSColor(white: 0, alpha: 0.45)
    static let fill = NSColor.white
}

struct KitShadow: Equatable {
    var light: Swift.Float
    var dark: Swift.Float
    var radius: CGFloat
    var y: CGFloat
}

enum Grip {
    static let width: CGFloat = 4
    static let rest: CGFloat = 28
    static let lit: CGFloat = 40
    static let fade: CFTimeInterval = 0.15
}

enum Contrast {
    static var raised: Bool {
        if Store.testing, let test = Store.settings.object(forKey: "contrast.testRaised") as? Bool { return test }
        return NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
}

enum Motion {
    static var reduced: Bool {
        if Store.testing, let test = Store.settings.object(forKey: "motion.testReduced") as? Bool { return test }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var light: Bool {
        guard Store.settings.object(forKey: lightKey) as? Bool ?? true else { return false }
        if Store.testing, let test = Store.settings.object(forKey: "motion.testLowPower") as? Bool { return test }
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    nonisolated static let lightKey = "motion.light"

    static var calm: Bool { reduced || light }

    static let slide: TimeInterval = 0.16

    static var pane: TimeInterval { reduced ? 0 : slide }

    static let columnScroll: TimeInterval = 0.32

    static var fieldOutSeconds: Double? { reduced ? nil : 0.2 }

    static var spaceResponse: Double { light ? 0.16 : 0.22 }

    static var pageChange: CFTimeInterval? {
        reduced || light || (Store.testing && !Store.shownOnScreen) ? nil : 0.11
    }

    static let give: CGFloat = 0.97

    static let foldSettles: TimeInterval = 0.5

    static func fold(out: Bool) -> (response: Double, damping: Double) {
        out ? (0.28, 0.92) : (0.24, 1)
    }
}

enum CardEdge {
    static let shadow: Double = 0
}

enum Kick {
    case left, right, lift
}

enum PopupLook {
    static let corner: CGFloat = 14
    static let inset: CGFloat = 6
    static let row: CGFloat = 30
    static let rowCorner: CGFloat = corner - inset
    static let fontSize: CGFloat = 13
    static let font = NSFont.systemFont(ofSize: fontSize)
    static let gap: CGFloat = 6
    static let margin: CGFloat = 8
    static let shadow = KitShadow(light: 0.16, dark: 0.30, radius: 18, y: 6)
    static let room: CGFloat = shadow.radius + shadow.y
    static let ground = NSColor.windowBackgroundColor
    static let edge = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.10)
    }
    static let ink = NSColor.labelColor
    static let fadeIn: CFTimeInterval = 0.12
    static let fadeOut: CFTimeInterval = 0.10
    static let fromScale: CGFloat = 0.90
    static let toScale: CGFloat = 0.96
    static let grow = KitSpring(response: 0.26, damping: 0.80)

    static func surface(for content: NSSize, inset: CGFloat = inset) -> NSSize {
        NSSize(width: content.width + inset * 2, height: content.height + inset * 2)
    }
}
