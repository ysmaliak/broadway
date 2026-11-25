import AppKit

@MainActor
extension Browsers {
    static func agentsMayUse(_ browser: Browser) -> Bool {
        !browser.shut && !browser.keepsNothing
    }

    static func forAgents(front: Browser?, among all: [Browser]) -> Browser? {
        if let front, agentsMayUse(front) { return front }
        return all.last(where: agentsMayUse)
    }

    static var forAgents: Browser? { forAgents(front: front, among: all) }

    static func forAgents(keeping held: Browser?) -> Browser? {
        if let held, agentsMayUse(held) { return held }
        return forAgents
    }

    static func agentHome(keeping held: Browser? = nil) -> Browser? {
        forAgents(keeping: held) ?? all.first { !$0.keepsNothing }
    }

    static func agentWindow(keeping held: Browser?) -> Browser {
        if let held, agentsMayUse(held) { return held }
        return agentWindow()
    }

    static func agentWindow() -> Browser {
        if let found = forAgents { return found }
        if let kept = all.first(where: { $0.shut && !$0.keepsNothing && $0.window != nil }), let window = kept.window {
            kept.shut = false
            orderBehind(window)
            return kept
        }
        let browser = Browser(record: WindowRecord(space: Spaces.current))
        open(browser, frame: nil, behind: true)
        return browser
    }

    static func orderBehind(_ window: NSWindow) {
        guard !Store.unitTests, !(Store.testing && NSApp.isHidden) else { return }
        window.orderBack(nil)
    }
}
