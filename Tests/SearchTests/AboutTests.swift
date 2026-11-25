import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct AboutTests {
    private static let info: [String: Any] = ["CFBundleShortVersionString": "0.7.2", "CFBundleVersion": "202611251707"]

    private func icon() -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in true }
    }

    private func closePanels() {
        for window in AboutWindow.panels { window.close() }
    }

    @Test func thePanelIsToldTheNameTheVersionTheBuildTheIconAndTheCredits() throws {
        let shown = icon()

        let options = AboutWindow.options(info: Self.info, icon: shown)

        #expect(options[.applicationName] as? String == "Broadway")
        #expect(options[.applicationVersion] as? String == "0.7.2")
        #expect(options[.version] as? String == "202611251707")
        #expect((options[.applicationIcon] as? NSImage) === shown)
        let credits = try #require(options[.credits] as? NSAttributedString)
        #expect(credits.string == "broadwaybrowser.com\nSource code on GitHub")
        #expect(options.count == 5)
    }

    @Test(arguments: [
        ("202611251707", "202611251707", "Version 0.7.2 (202611251707)"),
        ("0.7.2", "", "Version 0.7.2"),
        ("", "", "Version 0.7.2"),
        (nil, "", "Version 0.7.2"),
    ] as [(String?, String, String)])
    func theBuildIsShownInBracketsOnlyWhenItSaysSomethingNew(build: String?, told: String, line: String) {
        var info: [String: Any] = ["CFBundleShortVersionString": "0.7.2"]
        if let build { info["CFBundleVersion"] = build }

        let options = AboutWindow.options(info: info, icon: icon())

        #expect(options[.version] as? String == told)
        #expect(AboutWindow.versionText(short: "0.7.2", build: build) == line)
    }

    @Test func theCreditsLinkTheSiteAndTheSourceInSmallSecondaryCentredText() throws {
        let credits = AboutWindow.credits
        let text = credits.string as NSString

        let site = text.range(of: "broadwaybrowser.com")
        let code = text.range(of: "Source code on GitHub")
        #expect(credits.attribute(.link, at: site.location, effectiveRange: nil) as? URL == URL(string: "https://broadwaybrowser.com"))
        #expect(credits.attribute(.link, at: code.location, effectiveRange: nil) as? URL == URL(string: "https://github.com/ysmaliak/broadway"))
        #expect(code.location != NSNotFound)
        var whole = NSRange()
        let font = credits.attribute(.font, at: 0, longestEffectiveRange: &whole, in: NSRange(location: 0, length: credits.length)) as? NSFont
        #expect(whole.length == credits.length)
        #expect(font == NSFont.systemFont(ofSize: NSFont.smallSystemFontSize))
        #expect(credits.attribute(.foregroundColor, at: 0, longestEffectiveRange: &whole, in: NSRange(location: 0, length: credits.length)) as? NSColor == .secondaryLabelColor)
        #expect(whole.length == credits.length)
        #expect((credits.attribute(.paragraphStyle, at: credits.length - 1, effectiveRange: nil) as? NSParagraphStyle)?.alignment == .center)
        #expect(!credits.string.contains(";"))
        #expect(credits.string.components(separatedBy: "\n").allSatisfy { !$0.hasSuffix(".") })
    }

    @Test func theAppsOwnVersionLineIsBuiltTheSameWay() {
        let info = Bundle.main.infoDictionary ?? [:]

        #expect(AboutWindow.version == AboutWindow.versionText(short: AboutWindow.short(info), build: info["CFBundleVersion"] as? String))
    }

    @Test func theStandardPanelWritesTheBuildOnceAndOpensOnlyOnce() throws {
        _ = NSApplication.shared
        autoreleasepool { closePanels() }
        defer { autoreleasepool { closePanels() } }
        let shown = icon()

        let first: NSWindow? = autoreleasepool {
            NSApp.orderFrontStandardAboutPanel(options: AboutWindow.options(info: Self.info, icon: shown))
            let panel = AboutWindow.panel
            panel?.setFrameOrigin(NSPoint(x: 40, y: 40))
            return panel
        }
        let (again, count, styled, texts): (NSWindow?, Int, Bool, [String]) = autoreleasepool {
            NSApp.orderFrontStandardAboutPanel(options: AboutWindow.options(info: Self.info, icon: shown))
            let panel = AboutWindow.panel
            return (panel, AboutWindow.panels.count, panel.map { $0.styleMask.contains(.titled) && $0.styleMask.contains(.closable) } ?? false,
                    panel?.contentView.map(AboutWindow.texts(in:)) ?? [])
        }
        autoreleasepool { closePanels() }
        let plain: [String] = autoreleasepool {
            NSApp.orderFrontStandardAboutPanel(options: AboutWindow.options(info: ["CFBundleShortVersionString": "0.7.2", "CFBundleVersion": "0.7.2"], icon: shown))
            return AboutWindow.panel?.contentView.map(AboutWindow.texts(in:)) ?? []
        }

        let opened = try #require(first)
        #expect(opened === again)
        #expect(again?.frame.origin == NSPoint(x: 40, y: 40))
        #expect(count == 1)
        #expect(styled)
        #expect(texts.contains("Broadway"))
        #expect(texts.contains("Version 0.7.2 (202611251707)"))
        #expect(texts.filter { $0.contains("202611251707") }.count == 1)
        #expect(plain.contains("Version 0.7.2"))
        #expect(!plain.contains { $0.contains("(") })
    }
}
