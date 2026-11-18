import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct SettingsStageClickTests {
    private static let offsets: [CGFloat] = [0, 20, 42, 60, 120, 200]

    private func world() -> Browser {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        keepSetting(prefs, \.usesSpaces, "spaces")
        prefs.usesSpaces = true
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.spaces.append(Space(id: UUID(), name: "Work", colour: 1, icon: TabIcon(symbol: "briefcase")))
        return browser
    }

    private func forms(_ browser: Browser, asked: String) throws -> [(name: String, window: NSWindow, split: SettingsSplit)] {
        let stood = SettingsWindow.frame(browser, asked: asked)
        stood.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        let held = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 860, height: 640),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        held.isReleasedWhenClosed = false
        let tab = SettingsTab(browser: browser, asked: asked)
        let holder = NSViewController()
        holder.view = tab
        held.contentViewController = holder
        held.setContentSize(NSSize(width: 860, height: 640))
        for window in [stood, held] as [NSWindow] { window.layoutIfNeeded() }
        return [("window", stood, try #require(stood.contentViewController as? SettingsSplit)), ("tab", held, tab.split)]
    }

    private func scroll(_ split: SettingsSplit, in window: NSWindow, by offset: CGFloat) async throws {
        let clip = split.paper.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: split.paper.top + offset), size: clip.bounds.size)).origin)
        split.paper.reflectScrolledClipView(split.paper.contentView)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
    }

    private func spot(of view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    private func hit(_ point: NSPoint, in window: NSWindow) -> NSView? {
        guard let frame = window.contentView?.superview else { return nil }
        return frame.hitTest(frame.convert(point, from: nil))
    }

    private func inSight(_ point: NSPoint, of split: SettingsSplit) -> Bool {
        let pane = split.pane.convert(point, from: nil)
        let foot = split.pane.folded ? split.pane.safeAreaInsets.top : split.pane.wellFrame.maxY
        return pane.y > foot + 1 && split.paper.frame.insetBy(dx: 0, dy: 1).contains(pane)
    }

    private func press(_ point: NSPoint, in window: NSWindow) -> Bool {
        guard let control = hit(point, in: window) as? NSControl, control.isEnabled else { return false }
        control.performClick(nil)
        return true
    }

    private func covered(_ point: NSPoint, by split: SettingsSplit) -> Bool {
        let pane = split.pane.convert(point, from: nil)
        return split.pane.covers(point) && split.paper.frame.insetBy(dx: 0, dy: 1).contains(pane)
    }

    private func owns(_ found: NSView?, _ row: NSView) -> Bool {
        found === row || found?.isDescendant(of: row) == true
    }

    @Test func theFirstRowInSightUnderTheHeaderTakesItsClickAndRowsUnderItDoNot() async throws {
        let browser = world()
        defer { browser.closeAll() }
        let made = try forms(browser, asked: "privacy")
        defer { made.forEach { $0.window.close() } }

        var tried = 0
        var hidden = 0
        var missed: [String] = []
        var leaked: [String] = []
        for place in SettingsStageMap.places {
            for form in made {
                form.split.shell.go(to: place.page)
                if let detail = place.detail { form.split.shell.drill(detail) }
                try await Task.sleep(for: .milliseconds(80))
                for offset in Self.offsets {
                    try await scroll(form.split, in: form.window, by: offset)
                    let name = "\(form.name) \(place.detail?.rawValue ?? place.page.rawValue) at \(offset)"
                    let rows = form.split.page.cards.flatMap(\.rows).map { row in (row, spot(of: (row as? SettingsRowView)?.control ?? row)) }
                    if let (row, point) = rows.first(where: { inSight($0.1, of: form.split) }) {
                        tried += 1
                        let found = hit(point, in: form.window)
                        if !owns(found, row) { missed.append("\(name): \(found.map { "\(type(of: $0))" } ?? "nothing")") }
                    }
                    for (row, point) in rows where covered(point, by: form.split) {
                        hidden += 1
                        if owns(hit(point, in: form.window), row) { leaked.append(name) }
                    }
                }
            }
        }

        #expect(tried == SettingsStageMap.places.count * made.count * Self.offsets.count)
        #expect(hidden >= SettingsStageMap.places.count * made.count)
        #expect(missed.isEmpty, "\(missed)")
        #expect(leaked.isEmpty, "\(leaked)")
    }

    @Test func aSwitchFlipsWhenClickedInSightAndNotWhenUnderTheHeader() async throws {
        let browser = world()
        defer { browser.closeAll() }
        let prefs = browser.prefs
        keepSetting(prefs, \.shielded, "shield")
        let made = try forms(browser, asked: "privacy")
        defer { made.forEach { $0.window.close() } }
        try await Task.sleep(for: .milliseconds(80))

        var flips: [String] = []
        var under: [String] = []
        var wrong: [String] = []
        for form in made {
            for offset in Self.offsets {
                try await scroll(form.split, in: form.window, by: offset)
                let toggle = try #require(form.split.page.named("shield")?.kitSubviews(of: KitSwitch.self).first)
                let point = spot(of: toggle)
                if covered(point, by: form.split) {
                    under.append("\(form.name) \(offset)")
                    if owns(hit(point, in: form.window), toggle) { wrong.append("\(form.name) under the header at \(offset)") }
                    continue
                }
                guard inSight(point, of: form.split) else { continue }
                let before = prefs.shielded
                let pressed = press(point, in: form.window)
                try await Task.sleep(for: .milliseconds(40))
                flips.append("\(form.name) \(offset)")
                if !pressed || prefs.shielded == before { wrong.append("\(form.name) at \(offset)") }
            }
        }

        #expect(flips.count >= made.count * 2)
        #expect(under.count >= made.count)
        #expect(wrong.isEmpty, "\(wrong)")
    }

    @Test func theSpacePopUpOnLiveFoldersTakesItsClickWhenThePageIsScrolled() async throws {
        let browser = world()
        defer { browser.closeAll() }
        let made = try forms(browser, asked: "livefolders")
        defer { made.forEach { $0.window.close() } }
        try await Task.sleep(for: .milliseconds(80))

        var tried: [String] = []
        var missed: [String] = []
        for form in made {
            for offset in [0, 20, 60, 120] as [CGFloat] {
                try await scroll(form.split, in: form.window, by: offset)
                let pop = try #require(form.split.page.kitSubviews(of: SettingsPopUp.self).first)
                let point = spot(of: pop)
                guard inSight(point, of: form.split) else { continue }
                tried.append("\(form.name) \(offset)")
                if hit(point, in: form.window) !== pop.button { missed.append("\(form.name) at \(offset)") }
            }
        }

        #expect(made.allSatisfy { $0.split.pane.folded && $0.split.page.heading != nil })
        #expect(tried.count >= made.count * 2)
        #expect(missed.isEmpty)
    }
}
