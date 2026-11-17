import AppKit
import ServiceManagement

@MainActor
protocol LoginItems: AnyObject {
    var on: Bool { get }
    func set(_ on: Bool) throws
}

@MainActor
final class MacLoginItems: LoginItems {
    var on: Bool { SMAppService.mainApp.status == .enabled }

    func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

@MainActor
final class LoginItemsStandIn: LoginItems {
    struct Refused: Error {}

    var on = false
    var refuses = false

    func set(_ on: Bool) throws {
        if refuses { throw Refused() }
        self.on = on
    }
}

@MainActor
enum OpenAtLogin {
    static let refusal = "Couldn't change Open at Login. You can do it in System Settings › General › Login Items."

    static let standIn = LoginItemsStandIn()
    private static var mac: MacLoginItems?

    static var items: LoginItems {
        if Store.testing { return standIn }
        if let mac { return mac }
        let made = MacLoginItems()
        mac = made
        return made
    }

    static var on: Bool { items.on }

    static func toggle(in browser: Browser) {
        if let refused = change(items) { browser.announce(refused) }
    }

    static func change(_ items: LoginItems) -> String? {
        let wanted = !items.on
        do {
            try items.set(wanted)
        } catch {
            return refusal
        }
        return items.on == wanted ? nil : refusal
    }
}
