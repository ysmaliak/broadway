import AppKit
import Foundation

final class ShieldOfferView: AskLine {
    let browser: Browser
    let shield: Shield
    var host: String {
        didSet {
            guard host != oldValue else { return }
            question.text = Self.words(blockers: Extensions.shared.blockers)
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    init(browser: Browser, shield: Shield, host: String) {
        self.browser = browser
        self.shield = shield
        self.host = host
        super.init(symbol: nil, text: Self.words(blockers: Extensions.shared.blockers), trailing: 9)
        keys = [
            KitGlassKey(title: "Not Now") { [weak shield] in shield?.offer = nil },
            KitGlassKey(title: "Allow Ads Here", kind: .primary) { [weak self] in self?.allow() },
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func words(blockers: [String]) -> String {
        guard let last = blockers.last else { return "Page not working?" }
        guard blockers.count > 1 else { return "Page not working? \(last) still blocks here. Pause it from its own button." }
        let names = blockers.dropLast().joined(separator: ", ") + " and " + last
        return "Page not working? \(names) still block here. Pause them from their own buttons."
    }

    private func allow() {
        shield.offer = nil
        Shield.shared.pause(host, true)
        browser.reload()
    }
}
