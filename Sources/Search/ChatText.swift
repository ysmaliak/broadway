import AppKit

enum ChatText {
    enum Block: Equatable {
        case words(NSAttributedString)
        case code(String)
    }

    static let size: CGFloat = 13
    static let line: CGFloat = 3
    static let gap: CGFloat = 8

    static var body: NSFont { .systemFont(ofSize: size) }
    static var mono: NSFont { .monospacedSystemFont(ofSize: size - 1.5, weight: .regular) }

    static func blocks(_ text: String, ink: NSColor = KitColor.ink) -> [Block] {
        var out: [Block] = []
        var words: [String] = []
        var code: [String]?
        func flushWords() {
            let kept = words
            words = []
            guard kept.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
            out.append(.words(paragraphs(kept, ink: ink)))
        }
        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let open = code {
                    out.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flushWords()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw) } else { words.append(raw) }
        }
        if let open = code { out.append(.code(open.joined(separator: "\n"))) }
        flushWords()
        return out
    }

    static func paragraphs(_ lines: [String], ink: NSColor = KitColor.ink) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var pending: [String] = []
        var first = true
        func put(_ piece: NSAttributedString) {
            if !first { out.append(NSAttributedString(string: "\n")) }
            first = false
            out.append(piece)
        }
        func flush() {
            guard !pending.isEmpty else { return }
            put(paragraph(pending.joined(separator: " "), ink: ink))
            pending = []
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }
            if let (mark, rest, depth) = item(raw) {
                flush()
                put(listItem(mark, rest, depth: depth, ink: ink))
            } else if let (level, rest) = heading(line) {
                flush()
                put(paragraph(rest, ink: ink, font: .systemFont(ofSize: level <= 2 ? size + 1 : size, weight: .semibold)))
            } else {
                pending.append(line)
            }
        }
        flush()
        return out
    }

    static func item(_ raw: String) -> (String, String, Int)? {
        let lead = raw.prefix { $0 == " " || $0 == "\t" }.count
        let line = raw.dropFirst(lead)
        let depth = min(3, lead / 2)
        for bullet in ["- ", "* ", "• ", "+ "] where line.hasPrefix(bullet) {
            return ("•", String(line.dropFirst(bullet.count)), depth)
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = line.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") { return ("\(digits).", String(after.dropFirst(2)), depth) }
        }
        return nil
    }

    static func heading(_ line: String) -> (Int, String)? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level), line.dropFirst(level).hasPrefix(" ") else { return nil }
        return (level, String(line.dropFirst(level + 1)))
    }

    static func style(indent: CGFloat = 0, first: CGFloat? = nil) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = line
        style.paragraphSpacing = gap
        style.lineBreakMode = .byWordWrapping
        style.headIndent = indent
        style.firstLineHeadIndent = first ?? indent
        if indent > 0 { style.tabStops = [NSTextTab(textAlignment: .left, location: indent)] }
        return style
    }

    static func paragraph(_ text: String, ink: NSColor, font: NSFont = body) -> NSAttributedString {
        let out = inline(text, ink: ink, font: font)
        out.addAttribute(.paragraphStyle, value: style(), range: NSRange(location: 0, length: out.length))
        return out
    }

    static func listItem(_ mark: String, _ text: String, depth: Int, ink: NSColor) -> NSAttributedString {
        let step: CGFloat = 18
        let indent = step * CGFloat(depth + 1)
        let out = NSMutableAttributedString(string: "\(mark)\t", attributes: [.font: body, .foregroundColor: KitColor.muted])
        out.append(inline(text, ink: ink, font: body))
        let paragraph = style(indent: indent, first: step * CGFloat(depth)).mutableCopy() as! NSMutableParagraphStyle
        paragraph.paragraphSpacing = gap / 2
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        return out
    }

    static func inline(_ text: String, ink: NSColor, font: NSFont) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        var plain = ""
        func flush() {
            guard !plain.isEmpty else { return }
            out.append(bareLinks(plain, base))
            plain = ""
        }
        var rest = Substring(text)
        while let first = rest.first {
            if first == "`", let end = rest.dropFirst().firstIndex(of: "`") {
                flush()
                let inner = rest[rest.index(after: rest.startIndex)..<end]
                out.append(NSAttributedString(string: String(inner), attributes: [
                    .font: mono, .foregroundColor: ink, .backgroundColor: Palette.NS.wash,
                ]))
                rest = rest[rest.index(after: end)...]
                continue
            }
            if rest.hasPrefix("**"), let end = rest.dropFirst(2).range(of: "**"), end.lowerBound > rest.index(rest.startIndex, offsetBy: 2) {
                flush()
                let inner = rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound]
                let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                out.append(bareLinks(String(inner), [.font: bold, .foregroundColor: ink]))
                rest = rest[end.upperBound...]
                continue
            }
            if first == "[", let close = rest.firstIndex(of: "]"), rest[rest.index(after: close)...].hasPrefix("("),
               let end = rest[close...].firstIndex(of: ")") {
                let label = String(rest[rest.index(after: rest.startIndex)..<close])
                let address = String(rest[rest.index(close, offsetBy: 2)..<end])
                if let url = link(address), !label.isEmpty {
                    flush()
                    var attributes = base
                    attributes[.link] = url
                    out.append(NSAttributedString(string: label, attributes: attributes))
                    rest = rest[rest.index(after: end)...]
                    continue
                }
            }
            plain.append(first)
            rest = rest.dropFirst()
        }
        flush()
        return out
    }

    static func link(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host() != nil
        else { return nil }
        return url
    }

    static func bareLinks(_ text: String, _ attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: attributes)
        guard text.contains("http"), let finder = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return out }
        for found in finder.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            guard let url = found.url, link(url.absoluteString) != nil else { continue }
            out.addAttribute(.link, value: url, range: found.range)
        }
        return out
    }

    static func plain(_ text: String) -> String {
        blocks(text).map { block in
            switch block {
            case .words(let words): return words.string
            case .code(let code): return code
            }
        }.joined(separator: "\n\n")
    }
}

final class ChatTextView: NSTextView {
    var opens: ((URL) -> Void)?

    convenience init(selectable: Bool) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        self.init(frame: NSRect(x: 0, y: 0, width: 200, height: 20), textContainer: container)
        container.widthTracksTextView = false
        container.size = NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude)
        isEditable = false
        isSelectable = selectable
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        isRichText = true
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .cursor: NSCursor.pointingHand]
        setAccessibilityElement(false)
    }

    func set(_ text: NSAttributedString) {
        guard textStorage?.isEqual(to: text) != true else { return }
        textStorage?.setAttributedString(text)
    }

    func height(for width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        if container.size.width != width { container.size = NSSize(width: max(1, width), height: .greatestFiniteMagnitude) }
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    func widest(for width: CGFloat) -> CGFloat {
        guard let text = textStorage, let container = textContainer else { return width }
        let pad = container.lineFragmentPadding * 2
        let box = text.boundingRect(with: NSSize(width: max(1, width - pad), height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(width, ceil(box.width) + pad)
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, ChatText.link(url.absoluteString) != nil else { return }
        opens?(url)
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
