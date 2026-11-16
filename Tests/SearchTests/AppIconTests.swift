import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct AppIconTests {
    private let tiny = NSSize(width: 16, height: 16)

    private func held(_ view: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let holder = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = holder
        view.frame = holder.bounds
        holder.addSubview(view)
        holder.layoutSubtreeIfNeeded()
        return window
    }

    private func pictures() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("broadway-app-icons-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let colours: [AppIcon: NSColor] = [.night: NSColor(deviceRed: 0.1, green: 0.1, blue: 0.12, alpha: 1),
                                           .day: NSColor(deviceRed: 0.97, green: 0.97, blue: 0.98, alpha: 1),
                                           .ink: NSColor(deviceRed: 0.12, green: 0.12, blue: 0.14, alpha: 1),
                                           .volt: NSColor(deviceRed: 0.25, green: 0.2, blue: 0.98, alpha: 1),
                                           .citrus: NSColor(deviceRed: 0.98, green: 0.85, blue: 0.2, alpha: 1)]
        for (icon, colour) in colours {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
            for x in 0..<16 { for y in 0..<16 { rep.setColor(colour, atX: x, y: y) } }
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: folder.appendingPathComponent(icon.rawValue + ".png"))
        }
        return folder
    }

    private func using(_ folder: URL, baked: AppIcon) {
        let folderBefore = AppIconShown.folder
        let bakedBefore = AppIconShown.baked
        AppIconShown.folder = folder
        AppIconShown.baked = baked
        addTeardownBlock {
            AppIconShown.folder = folderBefore
            AppIconShown.baked = bakedBefore
            AppIconShown.shown = nil
            AppIconShown.apply(Shared.prefs.appIcon)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func appearance(_ browser: Browser) -> (SettingsPageView, NSWindow) {
        let shell = SettingsShell()
        shell.go(to: .appearance)
        let page = SettingsPageView(browser: browser, shell: shell)
        let window = held(page, size: NSSize(width: 640, height: 1800))
        page.rebuild()
        page.layoutSubtreeIfNeeded()
        return (page, window)
    }

    @Test func theIconIsInkUntilChosenAndAnythingElseReadsAsInk() {
        let prefs = Shared.prefs
        keepSetting(prefs, \.appIcon, AppIcon.key)
        Store.settings.removeObject(forKey: AppIcon.key)

        let fresh = Preferences().appIcon
        Store.settings.set("purple", forKey: AppIcon.key)
        let bad = Preferences().appIcon
        Store.settings.set("volt", forKey: AppIcon.key)
        let volt = Preferences().appIcon

        #expect(fresh == .ink)
        #expect(bad == .ink)
        #expect(volt == .volt)
        #expect(AppIcon.named(nil) == .ink)
        #expect(AppIcon.named("") == .ink)
        #expect(AppIcon.allCases.map(\.title) == ["Ink", "Night", "Day", "Volt", "Citrus"])
    }

    @Test func choosingACardWritesThePrefAndSetsTheRunningIconAndTheBakedOneShowsItsPictureAfter() throws {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        keepSetting(prefs, \.appIcon, AppIcon.key)
        prefs.appIcon = .day
        using(try pictures(), baked: .day)
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let (page, window) = appearance(browser)
        defer { window.close() }
        let row = try #require(page.kitSubviews(of: SettingsRowView.self).first { $0.rowID == AppIcon.key })
        let cards = try #require(row.control as? SettingsPictureChoice)

        cards.choose(3)

        let volt = try #require(AppIconShown.picture(.volt))
        #expect(prefs.appIcon == .volt)
        #expect(Store.settings.string(forKey: AppIcon.key) == "volt")
        #expect(AppIconShown.shown === volt)
        #expect(NSApplication.shared.applicationIconImage?.size == tiny)

        cards.choose(2)

        #expect(prefs.appIcon == .day)
        #expect(Store.settings.string(forKey: AppIcon.key) == "day")
        let day = try #require(AppIconShown.picture(.day))
        #expect(AppIconShown.shown === day)
        #expect(NSApplication.shared.applicationIconImage?.size == tiny)
    }

    @Test func theBakedColourLeavesTheBundlesIconUntilAnotherIsShownThenShowsItsOwnPicture() throws {
        _ = NSApplication.shared
        using(try pictures(), baked: .ink)
        AppIconShown.shown = nil

        AppIconShown.apply(.ink)

        #expect(AppIconShown.shown == nil)
        #expect(NSApplication.shared.applicationIconImage?.size != tiny)

        AppIconShown.apply(.day)

        let day = try #require(AppIconShown.picture(.day))
        #expect(AppIconShown.shown === day)

        AppIconShown.apply(.ink)

        let ink = try #require(AppIconShown.picture(.ink))
        #expect(AppIconShown.shown === ink)
        #expect(NSApplication.shared.applicationIconImage?.size == tiny)
    }

    @Test func aPickedCardFollowsThePrefWhenItChangesElsewhere() throws {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        keepSetting(prefs, \.appIcon, AppIcon.key)
        prefs.appIcon = .day
        using(try pictures(), baked: .day)
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let (page, window) = appearance(browser)
        defer { window.close() }
        let row = try #require(page.kitSubviews(of: SettingsRowView.self).first { $0.rowID == AppIcon.key })
        let cards = try #require(row.control as? SettingsPictureChoice)

        prefs.appIcon = .ink
        page.refresh()

        #expect(cards.picked == 0)
    }

    @Test func theAppearancePageHasAnAppIconSectionOfFourNamedCardsAfterNewTabs() throws {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        keepSetting(prefs, \.appIcon, AppIcon.key)
        prefs.appIcon = .volt
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }

        let (page, window) = appearance(browser)
        defer { window.close() }
        let rows = page.kitSubviews(of: SettingsRowView.self)
        let ids = rows.map(\.rowID)

        let row = try #require(rows.first { $0.rowID == AppIcon.key })
        let cards = try #require(row.control as? SettingsPictureChoice)
        #expect(row.title.stringValue == "Icon")
        #expect(cards.accessibilityLabel() == "Icon")
        #expect(cards.cards.map { $0.accessibilityLabel() } == ["Ink", "Night", "Day", "Volt", "Citrus"])
        #expect(cards.options.map(\.picture) == [.appIcon("ink"), .appIcon("night"), .appIcon("day"), .appIcon("volt"), .appIcon("citrus")])
        #expect(cards.picked == 3)
        let at = try #require(ids.firstIndex(of: AppIcon.key))
        let look = try #require(ids.firstIndex(of: "look"))
        let newTab = try #require(ids.firstIndex(of: "newtab.floating"))
        let sidebar = try #require(ids.firstIndex(of: "sidebar.button"))
        #expect(look < at && newTab < at && at < sidebar)
        #expect(SettingsIndex.items(in: "icon").map(\.id) == [AppIcon.key])
        #expect(SettingsIndex.item(AppIcon.key)?.page == .appearance)
    }

    @Test(arguments: ["app icon", "icon colour", "dock icon", "icon color", "night"])
    func findingFindsTheAppIcon(words: String) {
        let found = SettingsIndex.find(words)

        #expect(found.contains { $0.id == AppIcon.key }, "\(words)")
    }

    @Test func agentsReadAndSetTheIconAndAreRefusedABadOne() throws {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        keepSetting(prefs, \.appIcon, AppIcon.key)
        prefs.appIcon = .day
        let access = try #require(PersonSettings.table[AppIcon.key])
        let write = try #require(access.write)

        let wrote = write(prefs, "ink")
        let refused = write(prefs, "purple")

        #expect(PersonSettings.refusal(AppIcon.key, value: "ink") == nil)
        #expect(wrote)
        #expect(!refused)
        #expect(prefs.appIcon == .ink)
        #expect(access.read(prefs) as? String == "ink")
        #expect(access.takes == "ink, night, day, volt, citrus")
    }

    @Test func theAboutIconFollowsAChangeWhileItIsOpen() throws {
        _ = NSApplication.shared
        using(try pictures(), baked: .day)
        AppIconShown.apply(.day)
        let icon = AboutIcon()

        AppIconShown.apply(.volt)

        let volt = try #require(AppIconShown.picture(.volt))
        #expect(icon.image?.size == volt.size)
        #expect(icon.image?.size == tiny)

        AppIconShown.apply(.day)

        let day = try #require(AppIconShown.picture(.day))
        #expect(AppIconShown.shown === day)
        #expect(icon.image?.size == tiny)
    }
}
