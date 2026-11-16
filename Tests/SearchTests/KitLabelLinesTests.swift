import AppKit
import Testing
@testable import Search

@MainActor
struct KitLabelLinesTests {
    private let long = "[OCT-180] Reading width - Cap lists, settings, deck page, folders and account at the reading width by someone · Pull Request #24816 · octocorp/octo-ios"

    private func inked(_ label: KitLabel, frame: NSRect, in size: NSSize) throws -> ClosedRange<Int>? {
        let stage = KitFlippedView(frame: NSRect(origin: .zero, size: size))
        stage.appearance = NSAppearance(named: .aqua)
        label.frame = frame
        stage.addSubview(label)
        stage.layoutSubtreeIfNeeded()
        let rep = try #require(stage.bitmapImageRepForCachingDisplay(in: stage.bounds))
        stage.cacheDisplay(in: stage.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / size.height
        var rows: [Int] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                rows.append(Int(CGFloat(y) / scale))
                break
            }
        }
        guard let first = rows.first, let last = rows.last else { return nil }
        return first...last
    }

    @Test func aTitleLongerThanItsLinesStaysInsideItsFrame() throws {
        let label = KitLabel(long, font: .systemFont(ofSize: 13, weight: .semibold))
        label.lines = 2
        let line = NSLayoutManager().defaultLineHeight(for: label.font)
        let frame = NSRect(x: 10, y: 80, width: 200, height: ceil(line * 2))

        let rows = try #require(try inked(label, frame: frame, in: NSSize(width: 220, height: 200)))

        #expect(rows.lowerBound >= Int(frame.minY) - 1)
        #expect(rows.upperBound <= Int(frame.maxY) + 1)
        #expect(rows.upperBound - rows.lowerBound > Int(line))
    }

    @Test func theTextRectIsTheFrameWhenTheTextIsTaller() {
        let label = KitLabel(long, font: .systemFont(ofSize: 13, weight: .semibold))
        label.lines = 2
        let size = NSSize(width: 200, height: 32)

        let rect = label.textRect(in: size)

        #expect(rect == NSRect(origin: .zero, size: size))
        #expect(label.measure(width: 200).height > 64)
    }

    @Test func aShortTextStaysCentredInATallerFrame() {
        let label = KitLabel("Short", font: .systemFont(ofSize: 13))
        label.lines = 2
        let natural = label.measure(width: 200)

        let rect = label.textRect(in: NSSize(width: 200, height: 60))

        #expect(rect.height == natural.height)
        #expect(abs(rect.midY - 30) < 0.01)
    }

    @Test func oneLineKeepsItsNaturalHeightInATightFrame() {
        let label = KitLabel("One line", font: .systemFont(ofSize: 13))
        let natural = label.measure(width: .greatestFiniteMagnitude)

        let rect = label.textRect(in: NSSize(width: 200, height: natural.height - 3))

        #expect(rect.height == natural.height)
    }
}
