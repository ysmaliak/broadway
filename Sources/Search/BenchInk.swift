import AppKit

@MainActor
enum BenchInk {
    static let verbs: Set<String> = ["inks"]

    struct Mark {
        var kind: String
        var text: String
        var box: NSRect
        var size: CGFloat
        var muted: Bool
        var note = ""
    }

    private static func note(_ view: NSView) -> String {
        var at = view.superview
        var plated = false
        while let here = at {
            if here is NSGlassEffectView { plated = true }
            if here is FloatKeyView || here is FloatFeedbackView || here is FloatWaitingView || here is FloatScrubView { return "float" }
            if here is FloatLiveView, !plated { return "video" }
            if here is MeetingFaceView || here is MeetingJoinButton || here is MiniToggle { return "own" }
            if let face = here as? KitGlassFace, let plate = face.plate, plate !== Palette.NS.glassGround { return "own" }
            if here is MiniPlayerView || here is UpdateCardView { return "side" }
            if let row = here as? NSTableRowView, row.isSelected { return "picked" }
            if let key = here as? KitButton, !key.isEnabled, key.superview is FieldBarView { return "off" }
            at = here.superview
        }
        return ""
    }

    static func run(_ request: [String: Any], _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing, let window = browser.window else { return answer(["error": "inks needs a window on a --test run"]) }
        let wanted = request["under"] as? String ?? ""
        let tops = ([window] + (window.childWindows ?? [])).compactMap(\.contentView)
        let roots = wanted.isEmpty ? tops : tops.flatMap { named(wanted, in: $0) }
        guard !roots.isEmpty else { return answer(["error": "no view named \(wanted) is in the window"]) }
        if request["blank"] as? Bool == true { roots.forEach(blank) }
        if request["shown"] as? Bool == true { roots.forEach(show) }
        let tall = NSScreen.screens.first?.frame.maxY ?? 0
        var inks: [[String: Any]] = []
        for root in roots {
            guard let host = root.window, let content = host.contentView else { continue }
            for var mark in said(root) {
                guard let box = mark["box"] as? [CGFloat], box.count == 4 else { continue }
                let inWindow = NSRect(x: box[0], y: content.bounds.height - box[1] - box[3], width: box[2], height: box[3])
                let onScreen = host.convertToScreen(inWindow)
                mark["box"] = [onScreen.minX, tall - onScreen.maxY, onScreen.width, onScreen.height]
                inks.append(mark)
            }
        }
        answer(["inks": inks, "numbers": Array(Set(roots.compactMap { $0.window?.windowNumber }))])
    }

    static func named(_ name: String, in view: NSView) -> [NSView] {
        if view.isHidden { return [] }
        if String(describing: type(of: view)) == name { return [view] }
        return view.subviews.flatMap { named(name, in: $0) }
    }

    static func leaves(in view: NSView) -> [NSView] {
        if view.isHidden || ((view.alphaValue == 0 || view.layer?.opacity == 0) && !marked.contains(view)) { return [] }
        if inked(view) { return [view] }
        return view.subviews.flatMap(leaves)
    }

    private static func inked(_ view: NSView) -> Bool {
        if view is KitLabel || view is KitSymbol || view is PlayGlyph || view is SiteWrapLabel || view is LinkWordsView { return true }
        if view is NSTextField || view is NSTextView { return true }
        if let button = view as? NSButton { return !button.isBordered || button.subviews.isEmpty }
        if let picture = view as? NSImageView { return picture.image?.isTemplate == true }
        return false
    }

    static func blank(_ view: NSView) {
        for leaf in leaves(in: view) where leaf.alphaValue > 0 {
            leaf.alphaValue = 0
            marked.add(leaf)
        }
    }

    static func show(_ view: NSView) {
        for leaf in marked.allObjects { leaf.alphaValue = 1 }
        marked.removeAllObjects()
    }

    private static let marked = NSHashTable<NSView>.weakObjects()

    static func others(in view: NSView) -> [String] {
        if view.isHidden || inked(view) { return [] }
        let name = String(describing: type(of: view))
        if view.subviews.isEmpty { return name.hasPrefix("NS") || name.hasPrefix("_") || name.hasPrefix("CA") ? [] : [name] }
        return view.subviews.flatMap(others)
    }

    static func said(_ view: NSView) -> [[String: Any]] {
        view.layoutSubtreeIfNeeded()
        return leaves(in: view).flatMap { leaf in marks(leaf).map { mark -> Mark in
            var mark = mark
            mark.note = note(leaf)
            return mark
        } }.filter { $0.box.width >= 1 && $0.box.height >= 1 }.map {
            ["kind": $0.kind, "text": $0.text, "box": $0.box.asList, "size": $0.size, "muted": $0.muted, "note": $0.note]
        }
    }

    private static func placed(_ local: NSRect, of view: NSView) -> NSRect {
        let seen = local.intersection(view.visibleRect)
        guard !seen.isNull, !seen.isEmpty, seen.width * seen.height >= local.width * local.height * 0.5 else { return .zero }
        let inWindow = view.convert(seen, to: nil)
        let tall = view.window?.contentView?.bounds.height ?? 0
        return NSRect(x: inWindow.minX, y: tall - inWindow.maxY, width: inWindow.width, height: inWindow.height)
    }

    private static func quiet(_ colour: NSColor?) -> Bool {
        guard let colour = colour?.usingColorSpace(.sRGB) else { return false }
        return colour.alphaComponent < 0.8
    }

    private static func marks(_ view: NSView) -> [Mark] {
        let kind = String(describing: type(of: view))
        if let label = view as? KitLabel {
            guard !label.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            let size = label.runs.map(\.font.pointSize).min() ?? 0
            return [Mark(kind: kind, text: label.text, box: placed(drawn(label), of: label), size: size, muted: quiet(label.benchDrawn))]
        }
        if let symbol = view as? KitSymbol {
            guard symbol.image != nil else { return [] }
            return [Mark(kind: kind, text: symbol.name, box: placed(symbol.bounds, of: symbol), size: 0,
                         muted: quiet(symbol.contentTintColor) || symbol.opacity < 0.8)]
        }
        if let glyph = view as? PlayGlyph {
            guard glyph.image != nil else { return [] }
            return [Mark(kind: kind, text: glyph.name, box: placed(glyph.drawn, of: glyph), size: 0, muted: quiet(glyph.tint ?? glyph.contentTintColor))]
        }
        if let label = view as? SiteWrapLabel {
            guard !label.text.isEmpty else { return [] }
            let fit = label.measure(width: label.bounds.width)
            let box = NSRect(x: 0, y: 0, width: min(fit.width, label.bounds.width), height: min(fit.height, label.bounds.height))
            return [Mark(kind: kind, text: label.text, box: placed(box, of: label), size: label.font.pointSize,
                         muted: quiet(label.color.kitResolved(dark: label.kitDark)))]
        }
        if let words = view as? LinkWordsView {
            return [Mark(kind: kind, text: words.accessibilityValue() as? String ?? "", box: placed(words.bounds, of: words),
                         size: LinkWordsView.font.pointSize, muted: false)]
        }
        if let text = view as? NSTextView { return runs(of: text, kind: kind) }
        if let field = view as? NSTextField {
            let empty = field.stringValue.isEmpty
            let words = empty ? field.placeholderAttributedString?.string ?? field.placeholderString ?? "" : field.stringValue
            guard !words.isEmpty else { return [] }
            let font = field.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            let colour = empty ? field.placeholderAttributedString.flatMap { $0.length > 0 ? $0.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil }
                : field.textColor
            let wide = min(field.bounds.width, ceil((words as NSString).size(withAttributes: [.font: font]).width) + 6)
            let box = field.maximumNumberOfLines == 1 || field.usesSingleLineMode ? NSRect(x: 0, y: 0, width: wide, height: field.bounds.height) : field.bounds
            return [Mark(kind: empty ? "placeholder" : kind, text: words, box: placed(box, of: field), size: font.pointSize,
                         muted: empty || quiet(colour?.kitResolved(dark: field.kitDark)))]
        }
        if let button = view as? NSButton {
            let font = button.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            return [Mark(kind: kind, text: button.image == nil ? button.title : button.accessibilityLabel() ?? button.title, box: placed(button.bounds, of: button), size: font.pointSize, muted: !button.isEnabled)]
        }
        if let picture = view as? NSImageView {
            return [Mark(kind: "symbol", text: picture.image?.name() ?? "", box: placed(picture.bounds, of: picture), size: 0,
                         muted: quiet(picture.contentTintColor))]
        }
        return []
    }

    private static func drawn(_ label: KitLabel) -> NSRect {
        let bounds = label.bounds
        let fit = label.measure(width: label.lines == 1 ? .greatestFiniteMagnitude : bounds.width)
        let wide = min(bounds.width, ceil(fit.width))
        let tall = min(bounds.height, ceil(fit.height))
        let free = bounds.width - wide
        let x: CGFloat = switch label.alignment {
        case .center: free / 2
        case .right: free
        default: 0
        }
        return NSRect(x: x, y: (bounds.height - tall) / 2, width: wide, height: tall)
    }

    private static func runs(of text: NSTextView, kind: String) -> [Mark] {
        guard let storage = text.textStorage, storage.length > 0, let manager = text.textLayoutManager,
              let content = manager.textContentManager else { return [] }
        manager.ensureLayout(for: manager.documentRange)
        let origin = text.textContainerOrigin
        var out: [Mark] = []
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            let words = storage.attributedSubstring(from: range).string
            guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let span = NSTextRange(location: start, end: end) else { return }
            let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: NSFont.systemFontSize)
            let colour = attributes[.foregroundColor] as? NSColor
            let symbol = attributes[.attachment] != nil
            manager.enumerateTextSegments(in: span, type: .standard, options: []) { _, frame, _, _ in
                let box = placed(frame.offsetBy(dx: origin.x, dy: origin.y), of: text)
                if box.width >= 2 {
                    out.append(Mark(kind: symbol ? "symbol" : kind, text: String(words.prefix(40)), box: box, size: symbol ? 0 : font.pointSize,
                                    muted: quiet(colour)))
                }
                return true
            }
        }
        return out
    }
}

private extension NSRect {
    var asList: [CGFloat] { [minX, minY, width, height] }
}

final class BenchPictureGround: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let bands: [NSColor] = [
            .white, .black, NSColor(srgbRed: 0.91, green: 0.25, blue: 0.16, alpha: 1), NSColor(srgbRed: 0.96, green: 0.82, blue: 0.12, alpha: 1),
            NSColor(srgbRed: 0.11, green: 0.25, blue: 0.85, alpha: 1), .white, .black, NSColor(srgbRed: 0.18, green: 0.7, blue: 0.29, alpha: 1),
        ]
        let wide: CGFloat = 64
        let lean = bounds.height * 0.35
        var index = 0
        var x = -lean
        while x < bounds.width + lean {
            bands[index % bands.count].setFill()
            let band = NSBezierPath()
            band.move(to: NSPoint(x: x, y: 0))
            band.line(to: NSPoint(x: x + wide, y: 0))
            band.line(to: NSPoint(x: x + wide + lean, y: bounds.height))
            band.line(to: NSPoint(x: x + lean, y: bounds.height))
            band.close()
            band.fill()
            index += 1
            x += wide
        }
        var row = 0
        var y: CGFloat = 5
        while y < bounds.height {
            var dot = CGFloat(row % 2) * 7 + 3
            var count = 0
            while dot < bounds.width {
                (count % 3 == 0 ? NSColor.black : count % 3 == 1 ? NSColor.white : NSColor(srgbRed: 0.95, green: 0.45, blue: 0.1, alpha: 1)).setFill()
                NSBezierPath(ovalIn: NSRect(x: dot, y: y, width: 4, height: 4)).fill()
                dot += 14
                count += 1
            }
            y += 11
            row += 1
        }
    }
}
