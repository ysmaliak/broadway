import AppKit

indirect enum KitMenuItem {
    case action(String, symbol: String? = nil, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                on: Bool = false, enabled: Bool = true, id: String? = nil, run: () -> Void)
    case picture(String, NSImage?, run: () -> Void)
    case submenu(String, symbol: String? = nil, [KitMenuItem])
    case header(String)
    case separator
}

final class KitMenuAction: NSMenuItem {
    private var run: (() -> Void)?

    convenience init(_ title: String, key: String, run: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: key)
        self.run = run
        target = self
    }

    @objc private func fire() { run?() }
}

@MainActor
enum KitMenu {
    static func make(_ items: [KitMenuItem], title: String = "") -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        for item in items { menu.addItem(self.item(item)) }
        return menu
    }

    static func item(_ item: KitMenuItem) -> NSMenuItem {
        switch item {
        case let .action(title, symbol, key, modifiers, on, enabled, id, run):
            let made = KitMenuAction(title, key: key, run: run)
            made.keyEquivalentModifierMask = modifiers
            made.state = on ? .on : .off
            made.isEnabled = enabled
            if let symbol { made.image = KitGlyph.plain(symbol) }
            if let id { made.setAccessibilityIdentifier(id) }
            return made
        case let .picture(title, image, run):
            let made = KitMenuAction(title, key: "", run: run)
            made.image = image
            return made
        case let .submenu(title, symbol, items):
            let made = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if let symbol { made.image = KitGlyph.plain(symbol) }
            made.submenu = make(items, title: title)
            return made
        case .header(let title):
            return NSMenuItem.sectionHeader(title: title)
        case .separator:
            return .separator()
        }
    }

    static func note(_ text: String, width: Int = 46) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: wrap(text, width: width), attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    nonisolated static func wrap(_ text: String, width: Int) -> String {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if !line.isEmpty, line.count + 1 + word.count > width {
                lines.append(line)
                line = ""
            }
            line += line.isEmpty ? String(word) : " " + word
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }

    nonisolated static func middle(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        let head = (limit - 1) / 2
        let tail = limit - 1 - head
        return text.prefix(head) + "…" + text.suffix(tail)
    }

    static func popUp(_ menu: NSMenu, from rect: NSRect, of view: NSView) {
        let height = menu.size.height
        let inWindow = view.convert(rect, to: nil)
        let room = view.window?.contentView?.bounds.height ?? .greatestFiniteMagnitude
        let under = inWindow.minY
        let over = room - inWindow.maxY
        let below = under >= height + 4 || under >= over
        let y: CGFloat
        if below {
            y = view.isFlipped ? rect.maxY + 4 : rect.minY - 4
        } else {
            y = view.isFlipped ? rect.minY - 4 - height : rect.maxY + 4 + height
        }
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: y), in: view)
    }

    static func pop(_ items: [KitMenuItem], below view: NSView) {
        make(items).popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
    }
}
