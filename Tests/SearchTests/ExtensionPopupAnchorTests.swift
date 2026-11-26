import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ExtensionPopupAnchorTests {
    private func button(_ id: String) -> Extensions.Button {
        Extensions.Button(id: id, name: "Example", label: "Example", icon: nil, badge: "", enabled: true, pinned: true)
    }

    @Test func aStillCopyOfTheToolbarIsNeverWhereAPopupHangs() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let id = "anchor\(UUID().uuidString.prefix(8).lowercased())"
        defer { Extensions.shared.anchors[id] = nil }
        let still = ExtensionSlotView(extensions: .shared, still: true)
        window.contentView?.addSubview(still)
        still.addSubview(ExtensionActionButton(button: button(id)) { _ in })
        #expect(Extensions.shared.anchors[id] == nil)
        #expect(still.anchor(for: id) == nil)
        #expect(ExtensionSlotView.anchor(for: id, in: window) == nil)
    }

    @Test func aLiveToolbarInTheWindowGivesItsAnchor() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let still = ExtensionSlotView(extensions: .shared, still: true)
        let live = ExtensionSlotView(extensions: .shared)
        window.contentView?.addSubview(still)
        window.contentView?.addSubview(live)
        let anchor = ExtensionSlotView.anchor(for: "none", in: window)
        #expect(anchor != nil)
        #expect(anchor?.isDescendant(of: live) == true)
    }

    @Test func pressingAButtonMakesItTheAnchor() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let id = "anchor\(UUID().uuidString.prefix(8).lowercased())"
        defer { Extensions.shared.anchors[id] = nil }
        let first = ExtensionActionButton(button: button(id)) { _ in }
        let second = ExtensionActionButton(button: button(id)) { _ in }
        window.contentView?.addSubview(first)
        window.contentView?.addSubview(second)
        #expect(Extensions.shared.anchors[id]?.view === second)
        first.action?()
        #expect(Extensions.shared.anchors[id]?.view === first)
    }
}
