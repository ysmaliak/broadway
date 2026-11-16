import AppKit

enum LinkCopy {
    struct Link: Equatable {
        var title: String
        var url: URL

        init(_ title: String, _ url: URL) {
            self.title = title
            self.url = url
        }
    }

    enum Style: String, CaseIterable {
        case address, clean, markdown, rich
    }

    @MainActor static var board: NSPasteboard {
        Store.testing ? testBoard : .general
    }

    @MainActor private static let testBoard = NSPasteboard(name: NSPasteboard.Name("com.ysmaliak.broadway.test.links.\(getpid())"))

    static func cleaned(_ links: [Link]) -> [Link] {
        links.map { Link($0.title, CleanLink.clean($0.url)) }
    }

    static func text(of title: String, for url: URL) -> String {
        let flat = title
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if !flat.isEmpty { return flat }
        return url.host() ?? url.absoluteString
    }

    static func markdown(_ links: [Link]) -> String {
        links.map { markdown($0.title, $0.url) }.joined(separator: "\n")
    }

    static func markdown(_ title: String, _ url: URL) -> String {
        var label = ""
        for character in text(of: title, for: url) {
            if "\\[]".contains(character) { label.append("\\") }
            label.append(character)
        }
        return "[\(label)](\(markdownAddress(url)))"
    }

    static func markdownAddress(_ url: URL) -> String {
        url.absoluteString
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
    }

    static func html(_ links: [Link]) -> String {
        let anchors = links.map { link in
            "<a href=\"\(escape(link.url.absoluteString))\">\(escape(text(of: link.title, for: link.url)))</a>"
        }
        return "<meta charset=\"utf-8\">" + anchors.joined(separator: "<br>\n")
    }

    static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    static func rtf(_ links: [Link]) -> Data? {
        let whole = NSMutableAttributedString()
        for (index, link) in links.enumerated() {
            if index > 0 { whole.append(NSAttributedString(string: "\n")) }
            whole.append(NSAttributedString(string: text(of: link.title, for: link.url), attributes: [.link: link.url]))
        }
        return try? whole.data(from: NSRange(location: 0, length: whole.length),
                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    static func plain(_ links: [Link]) -> String {
        links.map(\.url.absoluteString).joined(separator: "\n")
    }

    @discardableResult
    static func copy(_ links: [Link], as style: Style, to board: NSPasteboard) -> Bool {
        guard !links.isEmpty else { return false }
        board.clearContents()
        switch style {
        case .address:
            board.setString(plain(links), forType: .string)
        case .clean:
            board.setString(plain(cleaned(links)), forType: .string)
        case .markdown:
            board.setString(markdown(cleaned(links)), forType: .string)
        case .rich:
            let clean = cleaned(links)
            board.setString(html(clean), forType: .html)
            if let rtf = rtf(clean) { board.setData(rtf, forType: .rtf) }
            board.setString(plain(clean), forType: .string)
        }
        return true
    }

    static func announcement(_ count: Int, as style: Style) -> String {
        let one = count == 1
        switch style {
        case .address: return one ? "Address copied" : "\(count) addresses copied"
        case .clean: return one ? "Clean link copied" : "\(count) clean links copied"
        case .markdown: return one ? "Markdown link copied" : "\(count) Markdown links copied"
        case .rich: return one ? "Rich link copied" : "\(count) rich links copied"
        }
    }

    static func title(_ style: Style, count: Int) -> String {
        guard count > 1 else {
            switch style {
            case .address: return "Copy Address"
            case .clean: return "Copy Clean Link"
            case .markdown: return "Copy as Markdown Link"
            case .rich: return "Copy as Rich Link"
            }
        }
        switch style {
        case .address: return "Copy \(count) Addresses"
        case .clean: return "Copy \(count) Clean Links"
        case .markdown: return "Copy \(count) as Markdown Links"
        case .rich: return "Copy \(count) as Rich Links"
        }
    }
}
