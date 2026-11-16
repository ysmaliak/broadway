import AppKit

struct SettingsStageLayout {
    let rect: CGRect
    let u: CGFloat
    let column: CGRect
    let page: CGRect
    let top: CGRect
    let pill: CGRect
    let pins: CGRect
    let tabs: CGRect
    let agents: CGRect
    let foot: CGRect
    let card: Bool

    init(_ scene: SettingsStageScene, in rect: CGRect) {
        self.rect = rect
        let u = rect.height / 62
        self.u = u
        card = scene.card
        let width = (31 * u).rounded()
        column = CGRect(x: scene.right ? rect.maxX - width : rect.minX, y: rect.minY, width: width, height: rect.height)
        let rest = CGRect(x: scene.right ? rect.minX : rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height)
        let inset = scene.card ? 2.4 * u : 0
        page = rest.insetBy(dx: inset, dy: inset)
        let left = column.minX + 2.5 * u
        let inner = column.width - 5 * u
        func band(_ y: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: left, y: rect.minY + y * u, width: inner, height: height * u)
        }
        top = band(2.4, 5)
        pill = band(9, 5.6)
        pins = band(16.6, 5.6)
        tabs = band(24.4, 22.6)
        agents = band(48.2, 6)
        foot = band(55.8, 4.4)
    }

    func frame(_ spot: SettingsStageSpot) -> CGRect {
        let pad = -1.3 * u
        switch spot {
        case .window: return rect.insetBy(dx: 2, dy: 2)
        case .side: return column.insetBy(dx: 1.1 * u, dy: 1.1 * u)
        case .top: return top.insetBy(dx: pad, dy: pad * 0.6)
        case .field: return pill.insetBy(dx: pad, dy: pad)
        case .tabs: return tabs.insetBy(dx: pad, dy: pad * 0.7)
        case .agents: return agents.insetBy(dx: pad, dy: pad * 0.8)
        case .page: return card ? page.insetBy(dx: pad * 0.8, dy: pad * 0.8) : page.insetBy(dx: 2, dy: 2)
        }
    }

    func radius(_ spot: SettingsStageSpot) -> CGFloat {
        switch spot {
        case .window: return 8
        case .side, .tabs: return 6
        case .page: return card ? 3.6 * u : 6
        default: return 5
        }
    }
}

enum SettingsStageArt {
    static let agent = NSColor(srgbRed: 0.6, green: 0.42, blue: 0.95, alpha: 1)
    static let live = NSColor(srgbRed: 0.2, green: 0.72, blue: 0.42, alpha: 1)
    static let advert = NSColor(srgbRed: 0.98, green: 0.65, blue: 0.2, alpha: 1)

    static func draw(_ scene: SettingsStageScene, in rect: CGRect, dark: Bool, context: CGContext) {
        let tones = PictureTones(dark: dark, tint: scene.tint)
        let layout = SettingsStageLayout(scene, in: rect)
        PictureArt.gradient(context, rect, tones.frame)
        column(scene, layout, tones: tones, context: context)
        page(scene, layout, tones: tones, context: context)
        let u = layout.u
        for index in 0..<3 {
            let center = CGPoint(x: rect.minX + 4.2 * u + CGFloat(index) * 3.6 * u, y: layout.top.midY)
            PictureArt.dot(context, center: center, side: 2.3 * u, tones.ink.withAlphaComponent(0.22))
        }
    }

    private static func column(_ scene: SettingsStageScene, _ layout: SettingsStageLayout, tones: PictureTones, context: CGContext) {
        let u = layout.u
        let ink = tones.ink
        let top = layout.top
        var x = scene.right ? top.minX + 0.6 * u : layout.rect.minX + 4.2 * u + 3 * 3.6 * u
        if scene.sideButton {
            let frame = CGRect(x: x, y: top.midY - 1.7 * u, width: 4.4 * u, height: 3.4 * u)
            PictureArt.stroke(context, frame, radius: 0.9 * u, width: max(0.8, 0.45 * u), ink.withAlphaComponent(0.6))
            let bar = scene.right ? frame.maxX - 1.6 * u : frame.minX + 1.2 * u
            PictureArt.fill(context, CGRect(x: bar, y: frame.minY + 0.4 * u, width: max(0.6, 0.4 * u), height: frame.height - 0.8 * u),
                            ink.withAlphaComponent(0.6))
            x = frame.maxX
        }
        let forward = top.maxX - 1.6 * u
        arrow(context, at: CGPoint(x: forward - 4.2 * u, y: top.midY), pointing: -1, size: 1.2 * u, ink.withAlphaComponent(0.6))
        arrow(context, at: CGPoint(x: forward, y: top.midY), pointing: 1, size: 1.2 * u, ink.withAlphaComponent(0.3))

        let pill = layout.pill
        PictureArt.capsule(context, pill, tones.well)
        PictureArt.ring(context, center: CGPoint(x: pill.minX + 2.6 * u, y: pill.midY), side: 1.8 * u, width: max(0.6, 0.35 * u),
                        ink.withAlphaComponent(0.45))
        PictureArt.capsule(context, CGRect(x: pill.minX + 4.6 * u, y: pill.midY - 0.8 * u, width: 11 * u, height: 1.6 * u),
                           ink.withAlphaComponent(0.42))
        if scene.door {
            let door = CGRect(x: pill.maxX - 4.4 * u, y: pill.midY - 1.3 * u, width: 2.6 * u, height: 2.6 * u)
            PictureArt.fill(context, door, ink.withAlphaComponent(0.4), radius: 0.7 * u)
            PictureArt.dot(context, center: CGPoint(x: door.maxX, y: door.midY), side: 1.2 * u, ink.withAlphaComponent(0.4))
        }

        let pins = layout.pins
        let gap = 1.4 * u
        let side = (pins.width - 2 * gap) / 3
        for index in 0..<3 {
            let tile = CGRect(x: pins.minX + CGFloat(index) * (side + gap), y: pins.minY, width: side, height: pins.height)
            PictureArt.fill(context, tile, tones.well, radius: 1.6 * u)
            let glyph = CGRect(x: tile.midX - 1.6 * u, y: tile.midY - 1.6 * u, width: 3.2 * u, height: 3.2 * u)
            if index == 0 {
                context.saveGState()
                PictureArt.clip(context, glyph, radius: 0.8 * u)
                PictureArt.fill(context, glyph, tones.page)
                PictureArt.fill(context, CGRect(x: glyph.minX, y: glyph.minY, width: glyph.width, height: 1.1 * u), PictureArt.alert)
                context.restoreGState()
                if scene.countdown {
                    let font = NSFont.monospacedDigitSystemFont(ofSize: max(5, u * 5 / 2), weight: .bold)
                    let label = NSAttributedString(string: "4m", attributes: [.font: font])
                    let badge = CGRect(x: tile.maxX - ceil(label.size().width) - 2.2 * u, y: tile.minY - 0.8 * u,
                                       width: ceil(label.size().width) + 2.4 * u, height: 3.6 * u)
                    PictureArt.capsule(context, badge, PictureArt.alert)
                    PictureArt.text("4m", font: font, color: .white, center: CGPoint(x: badge.midX, y: badge.midY))
                }
            } else {
                PictureArt.fill(context, glyph, PictureArt.sites[index], radius: 0.8 * u)
            }
        }

        list(scene, layout, tones: tones, context: context)

        if scene.agents {
            let card = layout.agents
            PictureArt.fill(context, card, tones.raised, radius: 1.6 * u)
            PictureArt.dot(context, center: CGPoint(x: card.minX + 2.6 * u, y: card.midY), side: 2.4 * u, agent)
            PictureArt.capsule(context, CGRect(x: card.minX + 5 * u, y: card.midY - 1.9 * u, width: 12 * u, height: 1.5 * u),
                               ink.withAlphaComponent(0.55))
            let track = CGRect(x: card.minX + 5 * u, y: card.midY + 0.6 * u, width: card.width - 7.4 * u, height: 1.1 * u)
            PictureArt.capsule(context, track, ink.withAlphaComponent(0.14))
            PictureArt.capsule(context, CGRect(x: track.minX, y: track.minY, width: track.width * 0.55, height: track.height), agent)
        }

        let foot = layout.foot
        let tray = CGRect(x: foot.minX + 0.8 * u, y: foot.midY - 1.5 * u, width: 3 * u, height: 3 * u)
        context.setStrokeColor(ink.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(max(0.7, 0.4 * u))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: tray.midX, y: tray.minY))
        context.addLine(to: CGPoint(x: tray.midX, y: tray.maxY - 0.9 * u))
        context.move(to: CGPoint(x: tray.midX - 1.1 * u, y: tray.maxY - 2 * u))
        context.addLine(to: CGPoint(x: tray.midX, y: tray.maxY - 0.9 * u))
        context.addLine(to: CGPoint(x: tray.midX + 1.1 * u, y: tray.maxY - 2 * u))
        context.move(to: CGPoint(x: tray.minX, y: tray.maxY))
        context.addLine(to: CGPoint(x: tray.maxX, y: tray.maxY))
        context.strokePath()
        let plus = CGPoint(x: foot.maxX - 2.2 * u, y: foot.midY)
        context.move(to: CGPoint(x: plus.x - 1.3 * u, y: plus.y))
        context.addLine(to: CGPoint(x: plus.x + 1.3 * u, y: plus.y))
        context.move(to: CGPoint(x: plus.x, y: plus.y - 1.3 * u))
        context.addLine(to: CGPoint(x: plus.x, y: plus.y + 1.3 * u))
        context.strokePath()
        if scene.stacked == false {
            let marks = [PictureArt.sites[1], PictureArt.sites[3], PictureArt.sites[2]]
            for index in 0..<3 {
                PictureArt.dot(context, center: CGPoint(x: foot.midX + CGFloat(index - 1) * 3.6 * u, y: foot.midY), side: 2.2 * u,
                               marks[index].withAlphaComponent(index == 0 ? 1 : 0.45))
            }
        }
    }

    private enum Line {
        case space(Int)
        case group
        case tab(Int, picked: Bool, inside: Bool)
        case folder
    }

    private static func lines(_ scene: SettingsStageScene) -> [Line] {
        let last: Line = scene.live ? .folder : .tab(3, picked: false, inside: false)
        if scene.stacked == true {
            if scene.grouped {
                return [.space(0), .group, .tab(0, picked: true, inside: true), .space(1), last]
            }
            return [.space(0), .tab(0, picked: true, inside: false), .tab(1, picked: false, inside: false), .space(1), last]
        }
        if scene.grouped {
            return [.group, .tab(0, picked: true, inside: true), .tab(2, picked: false, inside: true), last]
        }
        return [.tab(0, picked: true, inside: false), .tab(1, picked: false, inside: false), .tab(2, picked: false, inside: false), last]
    }

    private static func list(_ scene: SettingsStageScene, _ layout: SettingsStageLayout, tones: PictureTones, context: CGContext) {
        let u = layout.u
        let ink = tones.ink
        let area = layout.tabs
        let stacked = scene.stacked == true
        let tall = (stacked ? 4.2 : 4.6) * u
        let gap = (stacked ? 0.8 : 1.4) * u
        let marks = [PictureArt.sites[1], PictureArt.sites[3], PictureArt.sites[2]]
        let lengths: [CGFloat] = [11, 8, 12, 7]
        let all = lines(scene)
        var y = area.minY
        for (at, line) in all.enumerated() {
            switch line {
            case .space(let index):
                PictureArt.dot(context, center: CGPoint(x: area.minX + 1.7 * u, y: y + 1.6 * u), side: 2.4 * u,
                               marks[index].withAlphaComponent(index == 0 ? 1 : 0.6))
                PictureArt.capsule(context, CGRect(x: area.minX + 4.2 * u, y: y + 0.8 * u, width: (index == 0 ? 9 : 7) * u, height: 1.7 * u),
                                   ink.withAlphaComponent(index == 0 ? 0.7 : 0.32))
                y += 3.2 * u + 0.6 * u
            case .group:
                var inside = 0
                for next in all[(at + 1)...] {
                    guard case .tab(_, _, true) = next else { break }
                    inside += 1
                }
                let box = CGRect(x: area.minX, y: y, width: area.width, height: CGFloat(inside + 1) * (tall + gap) - gap)
                PictureArt.fill(context, box, ink.withAlphaComponent(0.06), radius: 1.6 * u)
                var x = area.minX + 1.4 * u
                let middle = y + tall / 2
                if scene.emoji {
                    x += PictureArt.text("✈️", font: .systemFont(ofSize: 2.9 * u), color: ink, left: x, middle: middle) + 1 * u
                } else {
                    let folder = CGRect(x: x, y: middle - 1.3 * u, width: 3.2 * u, height: 2.6 * u)
                    PictureArt.fill(context, folder, ink.withAlphaComponent(0.5), radius: 0.6 * u)
                    x = folder.maxX + 1.4 * u
                }
                PictureArt.capsule(context, CGRect(x: x, y: middle - 0.9 * u, width: 9 * u, height: 1.8 * u), ink.withAlphaComponent(0.7))
                y += tall + gap
            case let .tab(index, picked, inside):
                let row = CGRect(x: area.minX, y: y, width: area.width, height: tall)
                if picked { PictureArt.fill(context, row.insetBy(dx: inside ? 0.8 * u : 0, dy: 0), tones.raised, radius: 1.5 * u) }
                let glyph = CGRect(x: row.minX + (inside ? 3 : 1.4) * u, y: row.midY - 1.5 * u, width: 3 * u, height: 3 * u)
                PictureArt.fill(context, glyph, PictureArt.sites[index % PictureArt.sites.count], radius: 0.8 * u)
                PictureArt.capsule(context, CGRect(x: glyph.maxX + 1.6 * u, y: row.midY - 0.85 * u, width: lengths[index % 4] * u, height: 1.7 * u),
                                   ink.withAlphaComponent(picked ? 0.6 : 0.26))
                y += tall + gap
            case .folder:
                let row = CGRect(x: area.minX, y: y, width: area.width, height: tall)
                let center = CGPoint(x: row.minX + 2.9 * u, y: row.midY)
                PictureArt.dot(context, center: center, side: 1.3 * u, live)
                PictureArt.ring(context, center: center, side: 3 * u, width: max(0.6, 0.35 * u), live.withAlphaComponent(0.7))
                PictureArt.capsule(context, CGRect(x: row.minX + 6 * u, y: row.midY - 0.85 * u, width: 10 * u, height: 1.7 * u),
                                   ink.withAlphaComponent(0.42))
                y += tall + gap
            }
        }
    }

    private static func arrow(_ context: CGContext, at point: CGPoint, pointing: CGFloat, size: CGFloat, _ color: NSColor) {
        let tip = CGPoint(x: point.x + size * pointing, y: point.y)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(max(0.7, size * 0.36))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: point.x - size * pointing, y: point.y))
        context.addLine(to: tip)
        context.move(to: CGPoint(x: tip.x - size * 0.8 * pointing, y: tip.y - size * 0.8))
        context.addLine(to: tip)
        context.addLine(to: CGPoint(x: tip.x - size * 0.8 * pointing, y: tip.y + size * 0.8))
        context.strokePath()
    }

    private static func page(_ scene: SettingsStageScene, _ layout: SettingsStageLayout, tones: PictureTones, context: CGContext) {
        let u = layout.u
        let page = layout.page
        let radius = scene.card ? 3 * u : 0
        if scene.card {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 0.3 * u), blur: 1.6 * u, color: NSColor(white: 0, alpha: 0.1).cgColor)
            PictureArt.fill(context, page, tones.page, radius: radius)
            context.restoreGState()
        }
        context.saveGState()
        PictureArt.clip(context, page, radius: radius)
        PictureArt.fill(context, page, tones.page)
        switch scene.content {
        case .article: article(scene, in: page, u: u, tones: tones, context: context)
        case .newTab: newTab(in: page, u: u, ink: tones.pageInk, context: context)
        case .signIn(let fills): signIn(fills: fills, in: page, u: u, tones: tones, context: context)
        }
        if scene.floating {
            PictureArt.fill(context, page, NSColor(white: 0, alpha: 0.12))
            floatingField(in: page, u: u, tones: tones, context: context)
        }
        context.restoreGState()
        if scene.card {
            PictureArt.stroke(context, page, radius: radius, width: 0.5, tones.ink.withAlphaComponent(0.08))
        } else {
            let x = scene.right ? page.maxX - 0.3 * u : page.minX
            PictureArt.fill(context, CGRect(x: x, y: page.minY, width: max(0.5, 0.3 * u), height: page.height), tones.ink.withAlphaComponent(0.1))
        }
    }

    private static func article(_ scene: SettingsStageScene, in page: CGRect, u: CGFloat, tones: PictureTones, context: CGContext) {
        let ink = tones.pageInk
        let zoom = CGFloat(min(max(scene.zoom, 0.5), 2))
        let left = page.minX + 4 * u
        let room = page.width - 8 * u
        var y = page.minY + 4 * u
        PictureArt.capsule(context, CGRect(x: left, y: y, width: min(18 * u * zoom, room), height: 2.4 * u * zoom), ink.withAlphaComponent(0.7))
        y += 2.4 * u * zoom + 2.2 * u
        let hero = CGRect(x: left, y: y, width: room, height: 13 * u)
        context.saveGState()
        PictureArt.clip(context, hero, radius: 1.6 * u)
        context.setAlpha(0.9)
        PictureArt.gradient(context, hero, PictureArt.hero)
        context.restoreGState()
        if scene.video { player(scene.quality, in: hero, u: u, context: context) }
        y = hero.maxY + 2.6 * u
        let slot = CGRect(x: page.maxX - 4 * u - 16 * u, y: y, width: 16 * u, height: 11 * u)
        var text = room
        switch scene.ads {
        case .gone: break
        case .shown:
            text = room - slot.width - 3 * u
            PictureArt.fill(context, slot, advert.withAlphaComponent(0.9), radius: 1.4 * u)
            PictureArt.text("Ad", font: .systemFont(ofSize: max(6, 3.4 * u), weight: .bold), color: NSColor(white: 0, alpha: 0.55),
                            center: CGPoint(x: slot.midX, y: slot.midY))
        case .marked:
            text = room - slot.width - 3 * u
            context.saveGState()
            context.setStrokeColor(ink.withAlphaComponent(0.3).cgColor)
            context.setLineWidth(max(0.7, 0.4 * u))
            context.setLineDash(phase: 0, lengths: [1.6 * u, 1.4 * u])
            context.addPath(CGPath(roundedRect: slot.insetBy(dx: 0.4 * u, dy: 0.4 * u), cornerWidth: 1.4 * u, cornerHeight: 1.4 * u, transform: nil))
            context.strokePath()
            context.restoreGState()
            shield(context, in: CGRect(x: slot.midX - 2.4 * u, y: slot.midY - 2.8 * u, width: 4.8 * u, height: 5.6 * u), ink.withAlphaComponent(0.4))
        }
        let step = (1.6 * u + 2 * u) * zoom
        for width in [1, 0.88, 0.96, 0.6] as [CGFloat] {
            guard y + 1.6 * u * zoom < page.maxY - 2 * u else { break }
            PictureArt.capsule(context, CGRect(x: left, y: y, width: text * width, height: 1.6 * u * zoom), ink.withAlphaComponent(0.18))
            y += step
        }
    }

    private static func player(_ quality: String?, in hero: CGRect, u: CGFloat, context: CGContext) {
        let white = NSColor(white: 1, alpha: 0.92)
        let side = 5.2 * u
        let play = CGMutablePath()
        play.move(to: CGPoint(x: hero.midX - side * 0.38, y: hero.midY - side / 2))
        play.addLine(to: CGPoint(x: hero.midX + side * 0.5, y: hero.midY))
        play.addLine(to: CGPoint(x: hero.midX - side * 0.38, y: hero.midY + side / 2))
        play.closeSubpath()
        context.saveGState()
        context.setFillColor(white.cgColor)
        context.addPath(play)
        context.fillPath()
        context.restoreGState()
        let track = CGRect(x: hero.minX + 2 * u, y: hero.maxY - 2.4 * u, width: hero.width - 4 * u, height: 0.9 * u)
        PictureArt.capsule(context, track, NSColor(white: 1, alpha: 0.35))
        PictureArt.capsule(context, CGRect(x: track.minX, y: track.minY, width: track.width * 0.36, height: track.height), white)
        guard let quality else { return }
        let font = NSFont.systemFont(ofSize: max(6, 3 * u), weight: .bold)
        let wide = ceil((quality as NSString).size(withAttributes: [.font: font]).width) + 2.4 * u
        let badge = CGRect(x: hero.maxX - wide - 1.6 * u, y: hero.minY + 1.6 * u, width: wide, height: max(8, 4.4 * u))
        PictureArt.fill(context, badge, NSColor(white: 0, alpha: 0.5), radius: 1.2 * u)
        PictureArt.text(quality, font: font, color: white, center: CGPoint(x: badge.midX, y: badge.midY))
    }

    private static func shield(_ context: CGContext, in rect: CGRect, _ color: NSColor) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.18))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.5))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.85))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.5), control: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.85))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.18))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(color.cgColor)
        context.fillPath()
    }

    private static func newTab(in page: CGRect, u: CGFloat, ink: NSColor, context: CGContext) {
        let total = 5 * u + 3.4 * u + 4.6 * u
        let top = page.midY - total / 2
        let field = CGRect(x: page.midX - 17 * u, y: top, width: 34 * u, height: 5 * u)
        PictureArt.capsule(context, field, ink.withAlphaComponent(0.08))
        PictureArt.ring(context, center: CGPoint(x: field.minX + 2.8 * u, y: field.midY), side: 2 * u,
                        width: max(0.5, 0.3 * u), ink.withAlphaComponent(0.4))
        let row = 4 * 4.6 * u + 3 * 2.2 * u
        for index in 0..<4 {
            let tile = CGRect(x: page.midX - row / 2 + CGFloat(index) * 6.8 * u, y: field.maxY + 3.4 * u, width: 4.6 * u, height: 4.6 * u)
            PictureArt.fill(context, tile, PictureArt.sites[index], radius: 1.3 * u)
        }
    }

    private static func floatingField(in page: CGRect, u: CGFloat, tones: PictureTones, context: CGContext) {
        let height = 2.6 * u * 2 + 2.4 * u + 3 * (1.9 * u + 2.4 * u)
        let card = CGRect(x: page.midX - 17 * u, y: page.midY - 3 * u - height / 2, width: 34 * u, height: height)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 0.8 * u), blur: 4 * u, color: NSColor(white: 0, alpha: 0.25).cgColor)
        PictureArt.fill(context, card, tones.floating, radius: 2.8 * u)
        context.restoreGState()
        let ink = tones.pageInk
        let left = card.minX + 2.6 * u
        var y = card.minY + 2.6 * u
        PictureArt.ring(context, center: CGPoint(x: left + 1.2 * u, y: y + 1.2 * u), side: 2.4 * u, width: max(0.5, 0.3 * u), ink.withAlphaComponent(0.5))
        PictureArt.capsule(context, CGRect(x: left + 3.8 * u, y: y + 0.3 * u, width: 11 * u, height: 1.8 * u), ink.withAlphaComponent(0.5))
        y += 2.4 * u
        for (index, width) in ([18, 13, 16] as [CGFloat]).enumerated() {
            y += 1.9 * u
            PictureArt.fill(context, CGRect(x: left, y: y, width: 2.4 * u, height: 2.4 * u), PictureArt.sites[index], radius: 0.7 * u)
            PictureArt.capsule(context, CGRect(x: left + 3.8 * u, y: y + 0.4 * u, width: width * u, height: 1.6 * u), ink.withAlphaComponent(0.22))
            y += 2.4 * u
        }
    }

    private static func signIn(fills: Bool, in page: CGRect, u: CGFloat, tones: PictureTones, context: CGContext) {
        let ink = tones.pageInk
        let width = min(34 * u, page.width - 10 * u)
        let left = page.midX - width / 2
        var y = page.minY + 6.5 * u
        PictureArt.dot(context, center: CGPoint(x: page.midX, y: y + 2.6 * u), side: 5.2 * u, PictureArt.sites[1])
        y += 5.2 * u + 2.4 * u
        PictureArt.capsule(context, CGRect(x: page.midX - 8 * u, y: y, width: 16 * u, height: 2.2 * u), ink.withAlphaComponent(0.7))
        y += 2.2 * u + 3.4 * u
        var fields: [CGRect] = []
        for _ in 0..<2 {
            let field = CGRect(x: left, y: y, width: width, height: 5.4 * u)
            PictureArt.fill(context, field, ink.withAlphaComponent(0.07), radius: 1.6 * u)
            PictureArt.stroke(context, field, radius: 1.6 * u, width: max(0.5, 0.25 * u), ink.withAlphaComponent(0.14))
            fields.append(field)
            y = field.maxY + 2 * u
        }
        let button = CGRect(x: left, y: y + 0.6 * u, width: width, height: 5.4 * u)
        PictureArt.fill(context, button, PictureArt.sites[1], radius: 1.6 * u)
        PictureArt.capsule(context, CGRect(x: button.midX - 5 * u, y: button.midY - 0.9 * u, width: 10 * u, height: 1.8 * u),
                           NSColor(white: 1, alpha: 0.9))
        guard fills else {
            PictureArt.fill(context, CGRect(x: fields[0].minX + 2 * u, y: fields[0].midY - 1.6 * u, width: max(0.7, 0.4 * u), height: 3.2 * u),
                            ink.withAlphaComponent(0.6))
            return
        }
        PictureArt.capsule(context, CGRect(x: fields[0].minX + 2 * u, y: fields[0].midY - 0.9 * u, width: 15 * u, height: 1.8 * u),
                           ink.withAlphaComponent(0.55))
        for index in 0..<7 {
            PictureArt.dot(context, center: CGPoint(x: fields[1].minX + 2.8 * u + CGFloat(index) * 2.5 * u, y: fields[1].midY), side: 1.6 * u,
                           ink.withAlphaComponent(0.55))
        }
        let chip = CGRect(x: fields[0].maxX - 9 * u, y: fields[0].midY - 1.7 * u, width: 7.4 * u, height: 3.4 * u)
        PictureArt.capsule(context, chip, live.withAlphaComponent(0.9))
        PictureArt.dot(context, center: CGPoint(x: chip.minX + 1.9 * u, y: chip.midY), side: 1.6 * u, NSColor(white: 1, alpha: 0.95))
        PictureArt.capsule(context, CGRect(x: chip.minX + 3.4 * u, y: chip.midY - 0.5 * u, width: 2.8 * u, height: 1 * u),
                           NSColor(white: 1, alpha: 0.95))
    }
}
