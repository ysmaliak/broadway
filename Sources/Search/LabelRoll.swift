import AppKit

@MainActor
final class LabelRoll {
    fileprivate(set) var key: AnyHashable?
    fileprivate(set) var pieces: [NSView] = []
    fileprivate var mark = 0
    fileprivate(set) var curve: KitCurve = .none
    fileprivate var anchor: NSPoint?
    fileprivate var give: CGFloat = 0
    fileprivate var pending: ((CGSize) -> Void)?
    var busy: Bool { !pieces.isEmpty }
}

extension KitLabel {
    var rollShown: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        var at: NSView? = self
        while let view = at {
            if view.alphaValue <= 0.01 || (view.layer?.opacity ?? 1) <= 0.01 { return false }
            at = view.superview
        }
        if Store.testing, let test = Store.settings.object(forKey: "roll.testShown") as? Bool { return test }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    func roll(_ text: String, for key: AnyHashable?) {
        roll([Run(text: text, font: font)], for: key)
    }

    func roll(_ next: [Run], for key: AnyHashable?) {
        let state = rolled ?? LabelRoll()
        rolled = state
        let same = key != nil && state.key == key
        state.key = key
        let before = runs
        guard next != before else { return }
        let old = text
        let new = next.map(\.text).joined()
        let fits = lines == 1 && alignment != .center && alignment != .right && !old.isEmpty
            && measure(width: .greatestFiniteMagnitude).width <= bounds.width + 0.5
        let move = AddressMove.tick(old, new, same: same && fits, shown: rollShown, reduced: Motion.reduced)
        settleRoll()
        runs = next
        guard move != .still else { return }
        startRoll(move, from: before)
    }

    func settleRoll() {
        guard let state = rolled, state.busy else { return }
        state.mark += 1
        state.pending = nil
        state.anchor = nil
        for piece in state.pieces { piece.removeFromSuperview() }
        state.pieces = []
        needsDisplay = true
    }

    func placeRoll() {
        guard let state = rolled, let pending = state.pending else { return }
        state.pending = nil
        var delta = CGSize.zero
        if let anchor = state.anchor, window != nil {
            let was = convert(anchor, from: nil)
            if abs(was.x) <= state.give { delta.width = was.x }
        }
        pending(delta)
    }

    func rollCarry(_ view: NSView, from place: NSRect, or local: NSRect) {
        guard let state = rolled, state.busy, state.curve.animates, view.window != nil, let superview = view.superview, let layer = view.layer else { return }
        let now = view.frame
        var was = superview.convert(place, from: nil)
        if abs(was.minX - now.minX) > abs(was.width - now.width) + 1 || abs(was.minY - now.minY) > 1 { was = local }
        was.origin.y = now.minY
        guard abs(was.width - now.width) > 0.01 || abs(was.minX - now.minX) > 0.01 || abs(was.minY - now.minY) > 0.01 else { return }
        let anchor = layer.anchorPoint
        let size = NSValue(rect: CGRect(origin: layer.bounds.origin, size: was.size))
        let spot = NSValue(point: CGPoint(x: was.minX + anchor.x * was.width, y: was.minY + anchor.y * was.height))
        if let grow = state.curve.animation("bounds", from: size, to: NSValue(rect: layer.bounds)) {
            grow.fillMode = .backwards
            layer.add(grow, forKey: "roll.bounds")
        }
        if let move = state.curve.animation("position", from: spot, to: NSValue(point: layer.position)) {
            move.fillMode = .backwards
            layer.add(move, forKey: "roll.position")
        }
    }

    private func startRoll(_ move: AddressMove, from before: [Run]) {
        guard let state = rolled else { return }
        let after = runs
        let was = Self.offsets(before), now = Self.offsets(after)
        let wide = ceil(max(bounds.width, was.last ?? 0, now.last ?? 0)) + 2
        let height = bounds.height
        let lift = ceil(measure(width: .greatestFiniteMagnitude).height)
        let shift: CGSize = if case let .roll(down) = move { CGSize(width: 0, height: down ? lift : -lift) } else { .zero }
        let curve = move.curve
        func piece(_ runs: [Run], _ range: Range<Int>, _ at: [CGFloat]) -> NSView {
            let from = range.lowerBound == 0 ? -lift : at[range.lowerBound]
            let to = range.upperBound == at.count - 1 ? wide + lift : at[range.upperBound]
            let clip = NSView(frame: NSRect(x: from, y: 0, width: max(0, to - from), height: height))
            clip.wantsLayer = true
            clip.clipsToBounds = true
            clip.layer?.masksToBounds = true
            clip.autoresizingMask = [.height]
            clip.setAccessibilityElement(false)
            let made = KitLabel()
            made.runs = runs
            made.color = color
            made.opacity = opacity
            made.ink = ink
            made.setAccessibilityElement(false)
            made.frame = NSRect(x: -from, y: 0, width: wide, height: height)
            made.autoresizingMask = [.height]
            clip.addSubview(made)
            addSubview(clip)
            state.pieces.append(clip)
            return clip
        }
        var kept: [(NSView, CGFloat)] = []
        var leaving: [NSView] = []
        var coming: [NSView] = []
        for part in Ticks.parts(joined(before), joined(after)) {
            if !part.moves {
                kept.append((piece(after, part.new, now), was[part.old.lowerBound] - now[part.new.lowerBound]))
                continue
            }
            if !part.old.isEmpty { leaving.append(piece(before, part.old, was)) }
            if !part.new.isEmpty { coming.append(piece(after, part.new, now)) }
        }
        needsDisplay = true
        state.mark += 1
        let mark = state.mark
        state.curve = curve
        state.anchor = window.map { _ in convert(NSPoint.zero, to: nil) }
        state.give = abs((was.last ?? 0) - (now.last ?? 0)) + 2
        state.pending = { [weak self, weak state] delta in
            guard let self, let state, state.mark == mark else { return }
            var longest: CFTimeInterval = 0
            for (made, dx) in kept {
                let x = dx + delta.width
                guard abs(x) > 0.01, let layer = made.layer else { continue }
                let base = layer.position
                if let slide = curve.animation("position", from: NSValue(point: CGPoint(x: base.x + x, y: base.y)), to: NSValue(point: base)) {
                    slide.fillMode = .both
                    layer.add(slide, forKey: "glide.position")
                }
            }
            for made in leaving {
                made.setFrameOrigin(NSPoint(x: made.frame.minX + delta.width, y: made.frame.minY))
                if let layer = made.layer {
                    longest = max(longest, AddressMove.glide(layer, shift: CGSize(width: -shift.width, height: -shift.height), leaving: true, curve: curve))
                }
            }
            for made in coming {
                if let layer = made.layer { longest = max(longest, AddressMove.glide(layer, shift: shift, leaving: false, curve: curve)) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(longest, 0.4)) { [weak self, weak state] in
                guard let self, let state, state.mark == mark else { return }
                settleRoll()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.placeRoll() }
    }

    private typealias Ticks = AddressMove.Ticks

    private func joined(_ runs: [Run]) -> String { runs.map(\.text).joined() }

    static func offsets(_ runs: [Run]) -> [CGFloat] {
        let string = NSMutableAttributedString()
        for run in runs { string.append(NSAttributedString(string: run.text, attributes: [.font: run.font])) }
        let line = CTLineCreateWithAttributedString(string)
        let characters = Array(string.string)
        var offsets: [CGFloat] = []
        var utf16 = 0
        for character in characters {
            offsets.append(CTLineGetOffsetForStringIndex(line, utf16, nil))
            utf16 += character.utf16.count
        }
        offsets.append(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        return offsets
    }
}
