import AppKit

enum SurfaceLook {
    static let pad: CGFloat = 14
    static let cardCorner: CGFloat = 16
    static let bar: CGFloat = 40
    static let barLead: CGFloat = 16
    static let key: CGFloat = 22
    static let barTrail: CGFloat = (bar - key) / 2
    static let wordsToKeys: CGFloat = 12
    static let keyGap: CGFloat = 8
    static let field: CGFloat = 26
    static let fieldCorner: CGFloat = 8
    static let fieldLead: CGFloat = 8
    static let text: CGFloat = 13
    static let caption: CGFloat = 12
    static let title = NSFont.systemFont(ofSize: text, weight: .semibold)
    static let fieldFont = NSFont.systemFont(ofSize: text)
    static let captionFont = NSFont.systemFont(ofSize: caption)
}
