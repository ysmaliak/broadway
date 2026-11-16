import AppKit
import CoreText

enum KitTruncate {
    static func width(_ text: NSAttributedString) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil))
    }

    static func middle(_ text: String, attributes: [NSAttributedString.Key: Any], to width: CGFloat) -> (text: String, width: CGFloat) {
        let made = middleParts(text, attributes: attributes, to: width)
        return (made.head + (made.cut ? "…" : "") + made.tail, made.width)
    }

    static func middleParts(_ text: String, attributes: [NSAttributedString.Key: Any], to width: CGFloat)
        -> (head: String, tail: String, cut: Bool, width: CGFloat) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let whole = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard whole > width else { return (text, "", false, whole) }
        let token = self.width(NSAttributedString(string: "…", attributes: attributes))
        let characters = Array(text)
        var units = [0]
        for character in characters { units.append(units[units.count - 1] + character.utf16.count) }
        func size(_ head: Int, _ tail: Int) -> CGFloat {
            let cut = CTLineGetOffsetForStringIndex(line, units[head], nil)
            let resume = CTLineGetOffsetForStringIndex(line, units[characters.count - tail], nil)
            return cut + token + whole - resume
        }
        var low = 0, high = characters.count - 1
        var best: (head: String, tail: String, cut: Bool, width: CGFloat) = ("", "", true, token)
        func attempt(_ kept: Int) -> (head: String, tail: String, cut: Bool, width: CGFloat)? {
            for head in [kept / 2, kept - kept / 2] {
                let made = size(head, kept - head)
                if made <= width {
                    return (String(characters[0..<head]), String(characters[(characters.count - (kept - head))...]), true, made)
                }
            }
            return nil
        }
        while low <= high {
            let mid = (low + high) / 2
            if let found = attempt(mid) {
                best = found
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        var kept = Array(best.head)
        while let last = kept.last, last == "." || last == " " { kept.removeLast() }
        if kept.count != best.head.count {
            best = (String(kept), best.tail, true, size(kept.count, best.tail.count))
        }
        return best
    }

    static func drawMiddle(_ text: NSAttributedString, head: Int, tail: Int, at origin: CGPoint, flipped: Bool, in context: CGContext) {
        let line = CTLineCreateWithAttributedString(text)
        let attributes = text.length > 0 ? text.attributes(at: 0, effectiveRange: nil) : [:]
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        var ascent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, nil, nil)
        let cut = CTLineGetOffsetForStringIndex(line, head, nil)
        let resume = CTLineGetOffsetForStringIndex(line, text.length - tail, nil)
        let shift = cut + CGFloat(CTLineGetTypographicBounds(token, nil, nil, nil)) - resume
        context.saveGState()
        context.translateBy(x: origin.x, y: flipped ? origin.y + ascent : origin.y - ascent)
        if flipped { context.scaleBy(x: 1, y: -1) }
        context.textMatrix = .identity
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetStringIndices(run, CFRange(), &indices)
            var kept: [CGGlyph] = [], at: [CGPoint] = []
            for index in 0..<count where indices[index] < head || indices[index] >= text.length - tail {
                kept.append(glyphs[index])
                at.append(indices[index] < head ? positions[index] : CGPoint(x: positions[index].x + shift, y: positions[index].y))
            }
            guard !kept.isEmpty else { continue }
            let runAttributes = CTRunGetAttributes(run) as NSDictionary
            let font = runAttributes[kCTFontAttributeName] as! CTFont
            let color = runAttributes[NSAttributedString.Key.foregroundColor] as? NSColor ?? .textColor
            context.setFillColor(color.cgColor)
            CTFontDrawGlyphs(font, kept, at, kept.count, context)
        }
        context.textPosition = CGPoint(x: cut, y: 0)
        CTLineDraw(token, context)
        context.restoreGState()
    }

    static func line(_ text: NSAttributedString, to width: CGFloat, mode: CTLineTruncationType) -> CTLine? {
        let attributes = text.length > 0 ? text.attributes(at: 0, effectiveRange: nil) : [:]
        let dots = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        return CTLineCreateTruncatedLine(CTLineCreateWithAttributedString(text), Double(max(0, width)), mode, dots)
    }

    static func draw(_ line: CTLine, at origin: CGPoint, flipped: Bool, in context: CGContext) {
        var ascent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, nil, nil)
        context.saveGState()
        context.textMatrix = flipped ? CGAffineTransform(scaleX: 1, y: -1) : .identity
        context.textPosition = CGPoint(x: origin.x, y: flipped ? origin.y + ascent : origin.y - ascent)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    static func cut(_ text: NSAttributedString, to width: CGFloat, mode: CTLineTruncationType) -> (text: NSAttributedString, width: CGFloat) {
        let line = CTLineCreateWithAttributedString(text)
        let full = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard full > width else { return (text, full) }
        let attributes = text.length > 0 ? text.attributes(at: 0, effectiveRange: nil) : [:]
        let dots = NSAttributedString(string: "…", attributes: attributes)
        guard width > 0, let cut = CTLineCreateTruncatedLine(line, Double(width), mode, CTLineCreateWithAttributedString(dots)) else {
            return (NSAttributedString(), 0)
        }
        let ellipsis = (CTLineGetGlyphRuns(CTLineCreateWithAttributedString(dots)) as? [CTRun])?.first.flatMap(glyph)
        let source = text.string as NSString
        let made = NSMutableAttributedString()
        for run in CTLineGetGlyphRuns(cut) as? [CTRun] ?? [] {
            let range = CTRunGetStringRange(run)
            let token = CTRunGetGlyphCount(run) == 1 && glyph(run) == ellipsis
                && (range.length != 1 || source.substring(with: NSRange(location: range.location, length: 1)) != "…")
            if token {
                made.append(dots)
            } else if range.location + range.length <= text.length {
                made.append(text.attributedSubstring(from: NSRange(location: range.location, length: range.length)))
            }
        }
        return (made, CGFloat(CTLineGetTypographicBounds(cut, nil, nil, nil)))
    }

    private static func glyph(_ run: CTRun) -> CGGlyph? {
        guard CTRunGetGlyphCount(run) > 0 else { return nil }
        var one = CGGlyph()
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &one)
        return one
    }
}
