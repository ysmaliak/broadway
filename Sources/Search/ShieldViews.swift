import AppKit
import Foundation

final class ShieldOfferView: AskLine {
    let browser: Browser
    let shield: Shield
    var host: String

    init(browser: Browser, shield: Shield, host: String) {
        self.browser = browser
        self.shield = shield
        self.host = host
        super.init(symbol: nil, text: "Page not working?", trailing: 9)
        keys = [
            KitGlassKey(title: "Not Now") { [weak shield] in shield?.offer = nil },
            KitGlassKey(title: "Allow Ads Here", kind: .primary) { [weak self] in self?.allow() },
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func allow() {
        shield.offer = nil
        Shield.shared.pause(host, true)
        browser.reload()
    }
}
