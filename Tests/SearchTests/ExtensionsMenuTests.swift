import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct ExtensionsMenuTests {
    private func button(_ id: String, _ name: String, enabled: Bool = true, pinned: Bool = false) -> Extensions.Button {
        Extensions.Button(id: id, name: name, label: name, icon: nil, badge: "", enabled: enabled, pinned: pinned)
    }

    @Test func eachExtensionIsAnItemWithItsIconAndThePinsAreChecked() {
        _ = NSApplication.shared
        let buttons = [button("a", "Alpha", pinned: true), button("b", "Beta", enabled: false)]

        let menu = ExtensionsMenu.menu(for: .shared, buttons: buttons)

        #expect(menu.items.prefix(2).map(\.title) == ["Alpha", "Beta"])
        #expect(menu.items.prefix(2).allSatisfy { $0.image != nil && $0.isEnabled })
        #expect(menu.items[1].attributedTitle != nil)
        let pins = menu.items.first { $0.title == "Pin to Toolbar" }?.submenu
        #expect(pins?.items.map(\.title) == ["Alpha", "Beta"])
        #expect(pins?.items.map(\.state) == [.on, .off])
        #expect(menu.items.suffix(3).map(\.title) == ["Chrome Web Store", "Load Unpacked\u{2026}", "Manage Extensions"])
    }

    @Test func withNoneOnTheListSaysSoAndKeepsItsFoot() {
        _ = NSApplication.shared

        let menu = ExtensionsMenu.menu(for: .shared, buttons: [])

        #expect(menu.items.first?.title == "No extensions are on")
        #expect(menu.items.first?.isEnabled == false)
        #expect(!menu.items.contains { $0.title == "Pin to Toolbar" })
        #expect(menu.items.filter { !$0.isSeparatorItem }.count == 4)
    }
}
