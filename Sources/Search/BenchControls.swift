import AppKit

final class BroadwayGallery: NSView {
    private struct Shown {
        let title: String
        var hover = false
        var press = false
        var focus = false
        var enabled = true
    }

    private let states = [
        Shown(title: "Rest"),
        Shown(title: "Hover", hover: true),
        Shown(title: "Press", hover: true, press: true),
        Shown(title: "Focus", focus: true),
        Shown(title: "Off", enabled: false),
    ]

    private(set) var focusField: KitField?
    private let ground: NSColor

    init(ground: NSColor) {
        self.ground = ground
        super.init(frame: .zero)
        wantsLayer = true
        var y: CGFloat = 20
        for shown in states {
            let label = KitLabel(shown.title, font: .systemFont(ofSize: 11, weight: .medium), color: KitColor.muted)
            let primary = KitBroadwayButton("Create", kind: .primary)
            let secondary = KitBroadwayButton("Cancel", kind: .secondary)
            let small = KitBroadwayButton("Small", kind: .primary, small: true)
            let on = KitSwitch(isOn: true, label: "On")
            let off = KitSwitch(isOn: false, label: "Off")
            let choice = KitChoice("Density", options: [
                .init(title: "Comfortable", symbol: "square.grid.2x2"),
                .init(title: "Compact", symbol: "square.split.2x1"),
            ], picked: 0)
            let field = KitField(placeholder: "Name", text: shown.title == "Rest" ? "" : "Work")
            let marks = [18, 28, 32].map { side -> CloseMarkView in
                let mark = CloseMarkView()
                mark.side = CGFloat(side)
                mark.over = shown.hover
                mark.pressed = shown.press
                return mark
            }
            for button in [primary, secondary, small] { button.isEnabled = shown.enabled }
            for item in [on, off] { item.alphaValue = shown.enabled ? 1 : 0.45 }
            choice.isEnabled = shown.enabled
            field.isEnabled = shown.enabled
            if shown.focus { focusField = field }
            let row: [(NSView, CGFloat?)] = [(label, 44), (primary, nil), (secondary, nil), (small, nil), (on, nil), (off, nil),
                                             (choice, nil), (field, 130)] + marks.map { ($0, nil) }
            let height = row.map { $0.0.fittingSize.height }.max() ?? 28
            var x: CGFloat = 20
            for (view, width) in row {
                let fit = view.fittingSize
                let w = width ?? fit.width
                let h = view === label ? fit.height : (view is KitField ? max(fit.height, 28) : fit.height)
                view.frame = NSRect(x: x, y: y + (height - h) / 2, width: w, height: h)
                addSubview(view)
                x += w + 14
            }
            y += height + 14
        }
        frame = NSRect(x: 0, y: 0, width: 1240, height: y + 6)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        var colour = ground.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { colour = ground.cgColor }
        layer?.backgroundColor = colour
    }
}

@MainActor
enum BenchControls {
    static func render(_ request: [String: Any], answer: @escaping ([String: Any]) -> Void) {
        guard let path = request["path"] as? String else { return answer(["error": "controls needs a path"]) }
        let dark = (request["look"] as? String ?? "dark") == "dark"
        let colour = request["colour"] as? String
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var gallery: BroadwayGallery!
        (appearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            gallery = BroadwayGallery(ground: colour.map { SpaceLook(colour: $0).tint } ?? KitColor.ground)
        }
        let host = gallery!
        host.appearance = appearance
        let size = host.frame.size
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        if let field = host.focusField { window.makeFirstResponder(field.field) }
        host.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return answer(["error": "nothing drawn"]) }
            host.cacheDisplay(in: host.bounds, to: picture)
            do {
                try picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                answer(["saved": path, "width": size.width, "height": size.height])
            } catch { answer(["error": error.localizedDescription]) }
            window.contentView = nil
        }
    }
}
