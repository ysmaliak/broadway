import AppKit
import Testing
@testable import Search

@MainActor
private final class ClickOnly: NSView {
    override func mouseUp(with event: NSEvent) {}
}

@MainActor
@Suite("Every control VoiceOver reaches has a name", .sharedWorld, .timeLimit(.minutes(5)), .serialized)
struct AccessAuditTests {
    init() {
        _ = NSApplication.shared
    }

    private func host(_ views: [NSView]) -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        for (index, view) in views.enumerated() {
            view.frame = NSRect(x: 10, y: 10 + CGFloat(index) * 40, width: 120, height: 28)
            root.addSubview(view)
        }
        return root
    }

    @Test func findsAnUnlabelledIconButtonAndAClickableViewVoiceOverCannotSee() {
        let icon = KitButton(.plain(press: 0.9)) {}
        icon.content = KitSymbol("plus")
        let named = KitButton(.plain(press: 0.9), label: "New Tab") {}
        named.content = KitSymbol("plus")
        let root = host([icon, named, ClickOnly()])

        let gaps = AccessAudit.gaps(in: root)

        #expect(gaps.map(\.kind).sorted() == ["hidden from VoiceOver", "unlabelled"])
        #expect(gaps.contains { $0.kind == "unlabelled" && $0.type == "KitButton" })
        #expect(gaps.contains { $0.kind == "hidden from VoiceOver" && $0.type == "ClickOnly" })
    }

    @Test func aSettingsRowActsOnlyWhenItPresses() {
        let plain = SettingsRowView(id: "plain", symbol: nil, title: "Plain")
        let drill = SettingsDrillRow(id: "drill", symbol: "gearshape", title: "Drill") {}

        let gaps = AccessAudit.gaps(in: host([plain, drill]))

        #expect(!plain.acting)
        #expect(drill.acting)
        #expect(gaps.isEmpty, "\(gaps.map(\.report))")
    }

    @Test(arguments: ["general", "privacy", "passwords", "spaces", "ai", "accounts", "extensions", "about"])
    func settingsPagesHaveNoGaps(page: String) async throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let window = SettingsWindow.frame(browser, asked: page)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        defer {
            window.contentViewController = nil
            window.close()
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        let gaps = AccessAudit.gaps(in: window)

        #expect(gaps.isEmpty, "\(gaps.map { "\($0.kind) \($0.type) \($0.near) \($0.path)" })")
    }
}
