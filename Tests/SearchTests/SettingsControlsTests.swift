import AppKit
import Testing
@testable import Search

@Suite
@MainActor
struct SettingsControlsTests {
    private func laid(_ row: NSView, width: CGFloat = 600) -> NSView {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        window.contentView = holder
        row.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            row.topAnchor.constraint(equalTo: holder.topAnchor),
        ])
        holder.layoutSubtreeIfNeeded()
        return holder
    }

    private func baseline(_ text: NSTextField, in row: NSView) -> CGFloat {
        let frame = row.convert(text.bounds, from: text)
        return frame.minY + text.firstBaselineOffsetFromTop
    }

    private func middle(_ view: NSView, in row: NSView) -> CGFloat {
        row.convert(view.bounds, from: view).midY
    }

    @Test func aOneLineDrillRowPutsItsTitleOnTheValuesBaseline() {
        let row = SettingsDrillRow(id: "plans", symbol: "cpu", title: "Plans") {}
        row.mark.show(count: nil, value: "Not set up")

        _ = laid(row)

        #expect(abs(baseline(row.title, in: row) - baseline(row.mark.value, in: row)) < 0.5)
        #expect(abs(middle(row.title, in: row) - row.bounds.midY) < 1)
    }

    @Test func aOneLineSwitchRowCentresItsTitleOnTheSwitch() {
        let toggle = KitSwitch(isOn: true, small: true)
        let row = SettingsRowView(id: "a", symbol: "eye", title: "Keep an eye on things", control: toggle)

        _ = laid(row)

        #expect(abs(middle(row.title, in: row) - middle(toggle, in: row)) < 1)
        #expect(abs(middle(row.title, in: row) - row.bounds.midY) < 1)
    }

    @Test(arguments: [false, true])
    func aDimmedRowsChoiceTakesNoClick(off: Bool) throws {
        var picked: Int?
        let choice = KitChoice("Agents ask first", options: ["Ask", "Auto"].map { KitChoice.Option(title: $0) }, picked: 1) { picked = $0 }
        let row = SettingsRowView(id: "a", symbol: "hand.raised", title: "Agents ask first", control: choice)
        let holder = laid(row)
        let window = try #require(holder.window)
        let ask = try #require(choice.subviews.first { $0.accessibilityLabel() == "Ask" })
        let point = ask.convert(NSPoint(x: ask.bounds.midX, y: ask.bounds.midY), to: nil)
        row.dim(off)

        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            if type == .leftMouseDown { choice.mouseDown(with: event) } else { choice.mouseUp(with: event) }
        }

        #expect(picked == (off ? nil : 0))
        #expect(choice.isEnabled == !off)
        #expect(choice.alphaValue == 1)
        #expect(row.alphaValue == (off ? 0.5 : 1))
    }

    @Test func aDetailThatOnlyJustWrapsIsGivenTheHeightOfBothLines() {
        let row = SettingsRowView(id: "video.quality", symbol: nil, title: "YouTube quality",
                                  detail: "What a YouTube video opens at, on YouTube and in its players on other sites",
                                  control: KitSwitch(isOn: true, small: true))
        let holder = laid(row, width: 560)
        var cut: [CGFloat] = []

        for width in stride(from: CGFloat(560), through: 440, by: -0.5) {
            holder.setFrameSize(NSSize(width: width, height: 200))
            holder.layoutSubtreeIfNeeded()
            holder.layoutSubtreeIfNeeded()
            let bounds = NSRect(x: 0, y: 0, width: row.detail.bounds.width, height: 1000)
            let needs = row.detail.cell?.cellSize(forBounds: bounds).height ?? 0
            if row.detail.frame.height < needs - 0.5 { cut.append(width) }
        }

        #expect(cut.isEmpty)
    }

    @Test func aRowThatGainsADetailKeepsItsTitleAboveIt() {
        let row = SettingsDrillRow(id: "agents", symbol: "person.2", title: "Agents") {}
        row.mark.show(count: nil, value: "Off")
        let holder = laid(row)

        row.say("Ask before each step")
        holder.layoutSubtreeIfNeeded()

        let title = row.convert(row.title.bounds, from: row.title)
        let detail = row.convert(row.detail.bounds, from: row.detail)
        #expect(title.maxY <= detail.minY + 0.5)
        #expect(!row.detail.isHidden)
    }

    @Test(arguments: [false, true])
    func aSwitchIsInkWhenOnAndAFaintWashWhenOff(dark: Bool) throws {
        let toggle = KitSwitch(isOn: true, small: true)
        toggle.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        toggle.viewDidChangeEffectiveAppearance()
        let on = try #require(toggle.shownTrack.flatMap(NSColor.init(cgColor:)))
        toggle.set(false, animated: false)
        let off = try #require(toggle.shownTrack.flatMap(NSColor.init(cgColor:)))

        #expect(abs(on.alphaComponent - (dark ? 0.88 : 0.86)) < 0.001)
        #expect(abs(off.alphaComponent - (dark ? 0.16 : 0.12)) < 0.001)
        #expect(abs(KitSwitch.colors(on: false, dark: dark, lit: true).track.alphaComponent - off.alphaComponent - 0.04) < 0.001)
        #expect(KitSwitch.colors(on: true, dark: dark, lit: false).knob.whiteComponent == (dark ? 0.12 : 1))
    }

    @Test func settingsRowsUseBroadwaysSmallSwitch() {
        let label = "Example"

        let toggle = KitControls.toggle(id: "settings.example", label: label, isOn: true) { _ in }

        #expect(toggle.small)
        #expect(toggle.isOn)
    }

    @Test(arguments: [false, true])
    func buttonsComeInThreeKindsAt28Points(dark: Bool) {
        let primary = SettingsPill("Make Default", kind: .primary)
        let secondary = PagePill("File…")
        let destructive = SettingsPill("Forget", kind: .destructive)

        let ink = KitPill.fill(.primary, dark: dark)
        let grey = KitPill.fill(.secondary, dark: dark)

        #expect([primary, secondary, destructive].allSatisfy { $0.intrinsicContentSize.height == 28 })
        #expect(primary.look == .pill(.primary) && destructive.look == .pill(.destructive))
        #expect(abs(ink.alphaComponent - (dark ? 0.9 : 0.86)) < 0.001)
        #expect(ink.whiteComponent == (dark ? 1 : 0))
        #expect(KitPill.fill(.destructive, dark: dark) == grey)
        #expect(KitPill.ink(.primary) == KitColor.ground)
        #expect(KitPill.ink(.destructive) == .systemRed)
        #expect((primary.content as? KitLabel)?.color == KitColor.ground)
        #expect((destructive.content as? KitLabel)?.color == .systemRed)
    }
}
