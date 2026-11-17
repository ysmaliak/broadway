import AppKit
import Combine

@MainActor
protocol HandoffBoard: AnyObject {
    func offer(_ url: URL?)
}

@MainActor
final class MacHandoff: HandoffBoard {
    private var activity: NSUserActivity?

    func offer(_ url: URL?) {
        guard let url else {
            activity?.invalidate()
            activity = nil
            return
        }
        if let activity, activity.webpageURL == url {
            activity.becomeCurrent()
            return
        }
        activity?.invalidate()
        let made = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        made.webpageURL = url
        made.becomeCurrent()
        activity = made
    }
}

@MainActor
final class HandoffStandIn: HandoffBoard {
    private(set) var offered: URL?
    private(set) var told: [URL?] = []

    func offer(_ url: URL?) {
        offered = url
        told.append(url)
    }
}

@MainActor
enum Handoff {
    static let standIn = HandoffStandIn()
    private static var mac: MacHandoff?
    private static var watch: AnyCancellable?

    static var board: HandoffBoard {
        if Store.testing { return standIn }
        if let mac { return mac }
        let made = MacHandoff()
        mac = made
        return made
    }

    nonisolated static func offered(_ url: URL?, privateWindow: Bool, agent: Bool, own: Bool) -> URL? {
        guard !privateWindow, !agent, !own, let url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              let host = url.host()?.lowercased(), !host.isEmpty, !Address.isLocal(host: host)
        else { return nil }
        return url
    }

    nonisolated static func continued(_ url: URL?) -> URL? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    static func current() -> URL? {
        guard Front.shared.browserKey, let browser = Front.shared.browser, browser.isOpen, let tab = browser.active else { return nil }
        return offered(tab.address, privateWindow: browser.isPrivate || tab.shy, agent: tab.agent, own: tab.page != nil)
    }

    private static var told: URL??
    private static var closing: AnyCancellable?

    static func start() {
        guard watch == nil else { return }
        watch = kitObserve({ current() }) { _ in refresh() }
        closing = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .sink { _ in
                Task { @MainActor in refresh() }
            }
    }

    static func refresh() {
        let now = current()
        guard told != .some(now) else { return }
        told = .some(now)
        board.offer(now)
    }
}

extension Links {
    func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {
        userActivityType == NSUserActivityTypeBrowsingWeb
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = Handoff.continued(userActivity.webpageURL) else { return false }
        guard !Store.testing || Links.hearsOthers else { return true }
        Links.arrived(url)
        return true
    }
}
