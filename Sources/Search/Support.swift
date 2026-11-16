import AppKit
import Darwin

@MainActor
enum Support {
    nonisolated static let address = "support@broadwaybrowser.com"
    nonisolated static let source = URL(string: "https://github.com/ysmaliak/broadway")!
    static let noMail = "No mail app is set up. The address is copied."
    static var handed: [String] = []

    struct Hands {
        var handler: @MainActor (URL) -> String?
        var own: String?
        var open: @MainActor (URL) -> Void
        var copy: @MainActor (String) -> Void

        static var mac: Hands {
            Hands(
                handler: { url in
                    NSWorkspace.shared.urlForApplication(toOpen: url).map { Bundle(url: $0)?.bundleIdentifier ?? $0.path }
                },
                own: Bundle.main.bundleIdentifier,
                open: { url in
                    guard !Store.testing else { return Support.handed.append("open \(url.absoluteString)") }
                    NSWorkspace.shared.open(url)
                },
                copy: { text in
                    guard !Store.testing else { return Support.handed.append("copy \(text)") }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            )
        }
    }

    static func subject(version: String, build: String) -> String {
        "Broadway \(version) (\(build))"
    }

    static func body(version: String, build: String, system: String, model: String) -> String {
        ["", "", subject(version: version, build: build), system, model].joined(separator: "\r\n")
    }

    static func mail(version: String, build: String, system: String, model: String) -> URL {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=?#"))
        let encode = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = address
        parts.percentEncodedQueryItems = [
            URLQueryItem(name: "subject", value: encode(subject(version: version, build: build))),
            URLQueryItem(name: "body", value: encode(body(version: version, build: build, system: system, model: model))),
        ]
        return parts.url ?? URL(string: "mailto:\(address)")!
    }

    static func showSource(in browser: Browser) {
        guard !Store.testing else { return handed.append("show \(source.absoluteString)") }
        _ = browser.open(source, foreground: true)
    }

    static var here: URL {
        let info = Bundle.main.infoDictionary
        return mail(version: info?["CFBundleShortVersionString"] as? String ?? "dev",
                    build: info?["CFBundleVersion"] as? String ?? "dev",
                    system: system, model: model)
    }

    static var system: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        guard let build = sysctl("kern.osversion") else { return "macOS \(number)" }
        return "macOS \(number) (\(build))"
    }

    static var model: String {
        "\(sysctl("hw.model") ?? "Mac"), \(appleSilicon ? "Apple silicon" : "Intel")"
    }

    private static var appleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        let text = String(cString: bytes)
        return text.isEmpty ? nil : text
    }

    @discardableResult
    static func write(_ url: URL? = nil, hands: Hands = .mac, announce: (String) -> Void) -> Bool {
        let url = url ?? here
        guard let app = hands.handler(url), app != hands.own else {
            hands.copy(address)
            announce(noMail)
            return false
        }
        hands.open(url)
        return true
    }
}
