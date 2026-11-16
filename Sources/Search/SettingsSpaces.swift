import AppKit

enum SettingsSpaceChoice {
    static func offered(spaces: Int, usesSpaces: Bool, isPrivate: Bool) -> Bool {
        usesSpaces && !isPrivate && spaces > 1
    }

    static func resolve(picked: UUID?, current: UUID, spaces: [UUID], offered: Bool = true) -> UUID {
        guard offered, let picked, spaces.contains(picked) else { return current }
        return picked
    }

    static func added(_ name: String, to space: Space?, current: UUID) -> String {
        guard let space, space.id != current else { return "Added \(name)" }
        return "Added \(name) to \(space.name)"
    }

    static func key(_ spaces: [Space]) -> [String] {
        spaces.map { "\($0.id.uuidString)|\($0.name)|\($0.shownIcon.saved)|\(String(describing: $0.look))" }
    }
}

extension Space {
    static let settingsBadgeSide: CGFloat = 18

    @MainActor var settingsBadge: NSImage {
        let look = look ?? SpaceLook()
        let icon = shownIcon
        let emoji = icon.emoji?.isEmpty == false
        let glyph = emoji ? icon.image : icon.symbol.flatMap { KitGlyph.image($0, .init(size: 10, weight: .semibold)) }
        let side = Space.settingsBadgeSide
        let swatch = look.settingsSwatch
        let made = NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            if swatch.count > 1, let wash = NSGradient(colors: swatch.map(\.color)) {
                wash.draw(in: plate, angle: -45)
            } else {
                (swatch.first?.color ?? NSColor(white: dark ? 1 : 0, alpha: dark ? 0.14 : 0.08)).setFill()
                plate.fill()
            }
            NSColor(white: dark ? 1 : 0, alpha: 0.14).setStroke()
            plate.lineWidth = 1
            plate.stroke()
            guard let glyph, glyph.size.width > 0, glyph.size.height > 0 else { return true }
            let room = side - (emoji ? 5 : 6)
            let scale = min(room / glyph.size.width, room / glyph.size.height, emoji ? 1 : 1.2)
            let size = NSSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
            var rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            if emoji {
                glyph.draw(in: rect)
                return true
            }
            guard let context = NSGraphicsContext.current?.cgContext,
                  let mask = glyph.cgImage(forProposedRect: &rect, context: NSGraphicsContext.current, hints: nil) else { return true }
            let lightInk = swatch.isEmpty ? dark : swatch.map(\.l).reduce(0, +) / Double(swatch.count) < SpaceLook.settingsInkTurn
            context.saveGState()
            context.clip(to: rect, mask: mask)
            context.setFillColor(NSColor(white: lightInk ? 1 : 0, alpha: 0.86).cgColor)
            context.fill(rect)
            context.restoreGState()
            return true
        }
        made.isTemplate = false
        return made
    }
}

extension SpaceLook {
    static let settingsInkTurn = 0.66

    var settingsSwatch: [Oklch] {
        if let preset { return preset.swatch == 0 ? [] : [Oklch(hex: preset.hex)] }
        return picked.map { Oklch(hex: $0) }
    }
}

@MainActor
final class SettingsSpaceChip: NSStackView {
    init(_ space: Space) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        let badge = NSImageView(image: space.settingsBadge)
        badge.setAccessibilityElement(false)
        let name = SettingsText(space.name, font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
        addArrangedSubview(badge)
        addArrangedSubview(name)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(space.name)
        setAccessibilityValue(space.name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

extension SettingsPageView {
    var offersSpaces: Bool {
        SettingsSpaceChoice.offered(spaces: browser.spaces.count, usesSpaces: browser.prefs.usesSpaces, isPrivate: browser.isPrivate)
    }

    var spaceID: UUID {
        SettingsSpaceChoice.resolve(picked: shell.space, current: browser.spaceID, spaces: browser.spaces.map(\.id), offered: offersSpaces)
    }

    @discardableResult
    func spacePicker(_ detail: String) -> UUID {
        let browser = browser
        let shell = shell
        shape { [weak self] in AnyHashable(self?.spaceID) }
        shape { [weak self] in AnyHashable(self?.offersSpaces) }
        shape { SettingsSpaceChoice.key(browser.spaces) }
        let chosen = spaceID
        guard offersSpaces else { return chosen }
        let spaces = browser.spaces
        let holder = SettingsPopUp()
        let pop = holder.button
        for space in spaces {
            let item = NSMenuItem(title: space.name, action: nil, keyEquivalent: "")
            item.image = space.settingsBadge
            item.representedObject = space.id
            pop.menu?.addItem(item)
        }
        pop.selectItem(at: spaces.firstIndex { $0.id == chosen } ?? 0)
        pop.kitOnChange { control in
            let at = (control as? NSPopUpButton)?.indexOfSelectedItem ?? 0
            guard spaces.indices.contains(at) else { return }
            shell.space = spaces[at].id
        }
        pop.kitAccess(id: "settings.space", label: "Space")
        section {
            put(SettingsRowView(id: "settings.space", symbol: nil, title: "Space", detail: detail, control: holder))
        }
        return chosen
    }
}
