import AppKit

extension NSView {
    var kitScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
}

extension KitSymbol {
    func centre(in rect: NSRect) {
        let scale = kitScale
        let size = image?.size ?? rect.size
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.toNearestOrAwayFromZero) / scale }
        frame = NSRect(x: snap(rect.midX - size.width / 2), y: snap(rect.midY - size.height / 2), width: size.width, height: size.height)
    }
}

@MainActor
enum KitLabelFit {
    private final class Memo {
        var text = ""
        var font: NSFont?
        var width: CGFloat?
        var measured: CGFloat?
        var cutWidth: CGFloat?
        var cut: String?
    }

    private static let wholes = NSMapTable<KitLabel, NSString>.weakToStrongObjects()
    private static let shown = NSMapTable<KitLabel, NSString>.weakToStrongObjects()
    private static let memos = NSMapTable<KitLabel, Memo>.weakToStrongObjects()

    static func whole(_ label: KitLabel) -> String {
        if let seen = shown.object(forKey: label) as String?, seen == label.text, let whole = wholes.object(forKey: label) as String? {
            return whole
        }
        return label.text
    }

    private static func memo(_ label: KitLabel, _ text: String) -> Memo {
        let memo = memos.object(forKey: label) ?? Memo()
        if memo.text != text || memo.font != label.font {
            memo.text = text
            memo.font = label.font
            memo.width = nil
            memo.measured = nil
            memo.cutWidth = nil
            memo.cut = nil
        }
        memos.setObject(memo, forKey: label)
        return memo
    }

    static func width(_ label: KitLabel) -> CGFloat {
        let text = whole(label)
        guard text == label.text else {
            let memo = memo(label, text)
            if let width = memo.width { return width }
            let width = KitTruncate.width(NSAttributedString(string: text, attributes: [.font: label.font]))
            memo.width = width
            return width
        }
        guard label.runs.count == 1 else { return label.measure(width: .greatestFiniteMagnitude).width }
        let memo = memo(label, text)
        if let measured = memo.measured { return measured }
        let measured = label.measure(width: .greatestFiniteMagnitude).width
        memo.measured = measured
        return measured
    }

    static func tail(_ label: KitLabel, width: CGFloat) {
        let text = whole(label)
        let memo = memo(label, text)
        let fitted: String
        if memo.cutWidth == width, let cut = memo.cut {
            fitted = cut
        } else {
            fitted = KitTruncate.cut(NSAttributedString(string: text, attributes: [.font: label.font]), to: width, mode: .end).text.string
            memo.cutWidth = width
            memo.cut = fitted
        }
        wholes.setObject(text as NSString, forKey: label)
        shown.setObject(fitted as NSString, forKey: label)
        if label.text != fitted { label.text = fitted }
        label.setAccessibilityValue(text)
    }
}
