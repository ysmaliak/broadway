import AppKit

@MainActor
enum AboutWindow {
    static let name = "Broadway"
    static let site = URL(string: "https://broadwaybrowser.com")!
    static let source = URL(string: "https://github.com/ysmaliak/broadway")!
    static let lines: [(words: String, link: URL?)] = [
        ("broadwaybrowser.com", site),
        ("Source code on GitHub", source),
    ]

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return versionText(short: short(info), build: info["CFBundleVersion"] as? String)
    }

    static func short(_ info: [String: Any]) -> String {
        info["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static func build(short: String, build: String?) -> String {
        guard let build, !build.isEmpty, build != short else { return "" }
        return build
    }

    static func versionText(short: String, build: String?) -> String {
        let shown = Self.build(short: short, build: build)
        return shown.isEmpty ? "Version \(short)" : "Version \(short) (\(shown))"
    }

    static var credits: NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let text = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n")) }
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let link = line.link { attributes[.link] = link }
            text.append(NSAttributedString(string: line.words, attributes: attributes))
        }
        text.addAttributes([
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centred,
        ], range: NSRange(location: 0, length: text.length))
        return text
    }

    static func options(info: [String: Any], icon: NSImage) -> [NSApplication.AboutPanelOptionKey: Any] {
        let short = short(info)
        return [
            .applicationName: name,
            .applicationVersion: short,
            .version: build(short: short, build: info["CFBundleVersion"] as? String),
            .applicationIcon: icon,
            .credits: credits,
        ]
    }

    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: options(info: Bundle.main.infoDictionary ?? [:], icon: NSApp.applicationIconImage))
        NSApp.activate()
    }

    static func isPanel(_ window: NSWindow) -> Bool {
        guard window is NSPanel, let view = window.contentView else { return false }
        let words = texts(in: view)
        return words.contains(name) && words.contains { $0.hasPrefix("Version ") }
    }

    static var panels: [NSWindow] {
        NSApp.windows.filter { $0.isVisible && isPanel($0) }
    }

    static var panel: NSWindow? { panels.first }

    static var made: NSWindow? {
        NSApp.windows.first(where: isPanel)
    }

    static func texts(in view: NSView) -> [String] {
        var found: [String] = []
        if let field = view as? NSTextField { found.append(field.stringValue) }
        if let words = view as? NSTextView { found.append(words.string) }
        for child in view.subviews { found += texts(in: child) }
        return found
    }

}
