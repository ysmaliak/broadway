import AppKit

final class SettingsHead: NSView {
    static let above: CGFloat = 8
    static let below: CGFloat = 22
    static let words: CGFloat = 460

    let crumb = SettingsText("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    let title = SettingsText("", font: .systemFont(ofSize: 22, weight: .bold))
    let summary = SettingsText("", font: .systemFont(ofSize: 13), color: .secondaryLabelColor, wraps: true)

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("settings.head")
        crumb.identifier = NSUserInterfaceItemIdentifier("settings.head.crumb")
        title.identifier = NSUserInterfaceItemIdentifier("settings.head.title")
        summary.identifier = NSUserInterfaceItemIdentifier("settings.head.summary")
        title.setAccessibilityRole(.staticText)
        title.setAccessibilitySubrole(.init(rawValue: "AXHeading"))
        crumb.isHidden = true
        for view in [crumb, title, summary] {
            view.alignment = .center
            addSubview(view)
        }
        let wide = summary.widthAnchor.constraint(equalToConstant: Self.words)
        wide.priority = NSLayoutConstraint.Priority(240)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor),
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.trailingAnchor.constraint(equalTo: trailingAnchor),
            crumb.bottomAnchor.constraint(equalTo: title.topAnchor, constant: -1),
            crumb.leadingAnchor.constraint(equalTo: leadingAnchor),
            crumb.trailingAnchor.constraint(equalTo: trailingAnchor),
            summary.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            summary.centerXAnchor.constraint(equalTo: centerXAnchor),
            summary.widthAnchor.constraint(lessThanOrEqualToConstant: Self.words),
            summary.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            wide,
            summary.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(crumb parent: String?, title name: String, summary line: String) {
        if title.stringValue != name { title.stringValue = name }
        if summary.stringValue != line { summary.stringValue = line }
        if crumb.stringValue != parent ?? "" { crumb.stringValue = parent ?? "" }
        crumb.setAccessibilityLabel(parent.map { "In \($0)" })
        crumb.isHidden = parent == nil
    }
}
