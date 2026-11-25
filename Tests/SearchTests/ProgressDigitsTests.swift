import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct ProgressDigitsTests {
    init() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Updates.shared.unpretend()
    }

    private func drawn(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    @Test func aByteCountKeepsItsLengthAcrossARoundValue() {
        let pairs: [(Int64, Int64)] = [(10_000_000, 10_100_000), (1_000_000, 1_400_000), (100_000_000, 100_300_000),
                                       (1_000_000_000, 1_230_000_000), (1_200_000_000, 1_230_000_000), (2_000_000_000, 2_010_000_000)]
        for (round, next) in pairs {
            #expect(FetchEntry.bytes(round).count == FetchEntry.bytes(next).count, "\(FetchEntry.bytes(round)) \(FetchEntry.bytes(next))")
        }
        let total: Int64 = 150_000_000
        let before = FetchEntry.bench("report.pdf", .downloading, done: 10_900_000, total: total)
        let even = FetchEntry.bench("report.pdf", .downloading, done: 11_000_000, total: total)
        let after = FetchEntry.bench("report.pdf", .downloading, done: 11_100_000, total: total)
        #expect(before.sizeText.count == even.sizeText.count)
        #expect(even.sizeText.count == after.sizeText.count)
        #expect(FetchEntry.bench("clip.mov", .downloading, done: 48_000_000, total: 0).sizeText.count
            == FetchEntry.bench("clip.mov", .downloading, done: 48_100_000, total: 0).sizeText.count)
    }

    @Test func thePopoverRowsSizeHoldsItsWidthWhileTheDownloadRuns() throws {
        let cell = DownloadCell()
        cell.frame = NSRect(x: 0, y: 0, width: 320, height: DownloadCell.tall)
        var widths: [CGFloat] = []
        var keys: [[NSRect]] = []
        for done: Int64 in [11_100_000, 44_400_000, 10_000_000, 88_800_000] {
            let entry = FetchEntry.bench("report.pdf", .downloading, done: done, total: 150_000_000)
            cell.show(.entry(entry))
            cell.layoutSubtreeIfNeeded()
            let detail = try #require(cell.kitSubviews(of: NSTextField.self).first { $0.stringValue == entry.detailText })
            widths.append(drawn(detail.stringValue, try #require(detail.font)))
            keys.append(cell.kitSubviews(of: NSButton.self).map(\.frame))
        }
        #expect(Set(widths).count == 1, "\(widths)")
        #expect(Set(keys.map { $0.map(\.minX) }).count == 1, "\(keys)")
    }

    @Test func theDownloadsPageRowsStateHoldsItsWidthWhileTheDownloadRuns() throws {
        var widths: [CGFloat] = []
        var controls: [[CGFloat]] = []
        for done: Int64 in [11_100_000, 44_400_000, 10_000_000, 88_800_000] {
            let entry = FetchEntry.bench("report.pdf", .downloading, done: done, total: 150_000_000)
            let line = FetchLineView(entry: entry, pause: {}, resume: {}, retry: {}, cancel: {})
            line.frame = NSRect(x: 0, y: 0, width: 640, height: line.rowHeight)
            line.layoutSubtreeIfNeeded()
            let state = try #require(line.kitSubviews(of: KitLabel.self).first { $0.text == "Downloading · \(entry.sizeText)" })
            widths.append(state.intrinsicContentSize.width)
            #expect(state.frame.width == state.intrinsicContentSize.width, "\(state.text)")
            controls.append(line.kitSubviews(of: NSButton.self).map(\.frame.minX))
        }
        #expect(Set(widths).count == 1, "\(widths)")
        #expect(Set(controls).count == 1, "\(controls)")
    }

    @Test func theUpdateCardsPercentHoldsItsWidthAndPlace() throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 258, height: 640), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        browser.window = window
        let view = SideColumnView(browser: browser)
        window.contentView = view
        defer { Updates.shared.unpretend() }
        var widths: [CGFloat] = []
        var frames: [NSRect] = []
        var titles: [NSRect] = []
        for progress in [0.11, 0.44, 0.80] {
            Updates.shared.pretend(version: "0.7", build: "700", phase: .downloading, progress: progress, trouble: nil)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            let card = try #require(view.kitSubviews(of: UpdateCardView.self).first { !$0.isHiddenOrHasHiddenAncestor && $0.frame.height > 0 })
            card.layoutSubtreeIfNeeded()
            let shown = UpdateWords.percent(progress)
            let percent = try #require(card.kitSubviews(of: KitLabel.self).first { $0.text == shown && !$0.isHidden })
            widths.append(percent.intrinsicContentSize.width)
            frames.append(percent.frame)
            titles.append(try #require(card.kitSubviews(of: KitLabel.self).first { $0.text == UpdateCardLook.downloading }).frame)
        }
        #expect(Set(widths).count == 1, "\(widths)")
        #expect(Set(frames.map { [$0.minX, $0.width] }).count == 1, "\(frames)")
        #expect(Set(titles.map { [$0.minX, $0.width] }).count == 1, "\(titles)")
    }

    @Test func theSettingsVersionLineHoldsItsWidthWhileAnUpdateDownloads() throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let shell = SettingsShell()
        shell.go(to: .general)
        let view = SettingsPageView(browser: browser, shell: shell)
        view.rebuild()
        let version = try #require(view.kitSubviews(of: SettingsRowView.self).first { $0.rowID == "updates.version" })
        let lines = [0.11, 0.44, 0.80].map {
            UpdateWords.line(version: "Version 0.7.1 (701)", runs: true, status: UpdateWords.downloading($0), last: nil)
        }
        var widths: [CGFloat] = []
        for line in lines {
            version.say(line)
            #expect(version.detail.stringValue == line)
            widths.append(version.detail.attributedStringValue.size().width)
        }
        #expect(Set(widths).count == 1, "\(widths)")
        #expect(drawn(lines[0], SettingsMetrics.detailFont) != drawn(lines[1], SettingsMetrics.detailFont))
        #expect(version.detail.font?.pointSize == SettingsMetrics.detailFont.pointSize)
        let other = try #require(view.kitSubviews(of: SettingsRowView.self).first { $0.rowID == "updates.check" })
        #expect(other.detail.font == SettingsMetrics.detailFont)
    }
}
