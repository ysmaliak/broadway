import AppKit
import WebKit

extension Preferences {
    nonisolated static let textActionsKey = "ai.actions"
}

@MainActor
enum TextActions {
    nonisolated static let more = "more"
    static let inMenu = ["improve", "fix", "summarize"]
    nonisolated static let moreTitle = "More Commands…"

    nonisolated static func commandID(_ id: String) -> String { "edit.text." + id }

    nonisolated static let commandIDs: Set<String> = Set((TextCommand.standard.map(\.id) + [more]).map(commandID))

    nonisolated static var shortcuts: [Command] {
        TextCommand.standard.map { command in
            Command(commandID(command.id), command.name, .edit, nil) { $0.textCommand(command.id) }
        } + [Command(commandID(more), moreTitle, .edit, nil) { $0.moreCommands() }]
    }

    static func set(_ on: Bool, _ prefs: Preferences, in browsers: [Browser]? = nil) {
        prefs.textActions = on
        if !on { (browsers ?? Browsers.all).forEach { $0.closeSelection() } }
    }

    static func menuRows(on: Bool, offered: Bool, agentWorking: Bool, runs: (TextCommand) -> Bool) -> [String] {
        guard on, offered, !agentWorking else { return [] }
        let shown = inMenu.compactMap { id in TextCommand.standard.first { $0.id == id } }.filter(runs).map(\.id)
        return CommandStore.shared.active.contains(where: runs) ? shown + [more] : shown
    }

    static func agentTitle(_ plan: Plan) -> String { plan == .thisMac ? plan.name : plan.tool }

    static func runsOn(_ plan: Plan) -> String { plan == .thisMac ? "On this Mac" : "\(plan.tool), leaves this Mac" }

    nonisolated static let nothingConnected = "Install Claude Code or Codex and sign in"
}

extension Browser {
    func textActionsAllowed(on tab: Tab?) -> Bool {
        guard prefs.textActions, let tab, tab.isWeb, !tab.agentWorking else { return false }
        return true
    }

    func canRun(_ command: TextCommand, on tab: Tab?) -> Bool {
        guard textActionsAllowed(on: tab), let tab else { return false }
        return Plans.shared.looked ? choice(for: command, tab: tab) != nil : !tab.neverSent
    }

    func canRunAny(on tab: Tab?) -> Bool {
        CommandStore.shared.active.contains { canRun($0, on: tab) }
    }

    func textActionRows(on tab: Tab, offered: Bool) -> [String] {
        TextActions.menuRows(on: prefs.textActions, offered: offered && tab.isWeb, agentWorking: tab.agentWorking) { canRun($0, on: tab) }
    }

    func textRefusal(_ tab: Tab) -> String {
        if tab.neverSent { return "In a private window, the page isn't sent" }
        if Plans.shared.agent(prefs) == .thisMac { return "This Mac can't do that. Pick another agent in Settings › Agents." }
        return Plans.shared.trouble(prefs) ?? "Sign in to Claude Code or Codex first"
    }

    func lookAtPlans() {
        let plans = Plans.shared
        if !plans.looked, !plans.looking { Task { await plans.refresh() } }
    }
}

extension PageView {
    func addTextActions(to menu: NSMenu, picked: Bool) {
        let offered = textOffered == true
        textOffered = nil
        guard picked, let browser = Browsers.browser(for: window), let tab = browser.anyTab(for: self) else { return }
        browser.lookAtPlans()
        let rows = browser.textActionRows(on: tab, offered: offered)
        guard !rows.isEmpty else { return }
        var at = menu.items.count
        if let copy = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }) {
            at = copy + 1
            while at < menu.items.count, !menu.items[at].isSeparatorItem { at += 1 }
        }
        var made: [NSMenuItem] = [.separator()]
        for id in rows {
            let title = id == TextActions.more ? TextActions.moreTitle : TextCommand.standard.first { $0.id == id }?.name ?? id
            let item = NSMenuItem(title: title, action: #selector(takeTextAction(_:)), keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier("BroadwayTextAction." + id)
            item.target = self
            item.representedObject = id
            made.append(item)
        }
        made.append(.separator())
        for item in made {
            menu.insertItem(item, at: at)
            at += 1
        }
    }

    @objc private func takeTextAction(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let browser = Browsers.browser(for: window),
              let tab = browser.anyTab(for: self) else { return }
        if id == TextActions.more { browser.moreCommands(in: tab) } else { browser.textCommand(id, in: tab) }
    }
}

final class TextActionRelay: NSObject, WKScriptMessageHandler {
    static let name = "broadwayTextActions"

    weak var tab: Tab?

    static let watch = """
    (function () {
      if (window.__broadwayTextActions) return;
      window.__broadwayTextActions = true;
      \(PageSelection.secretCheck)
      function offered() {
        var el = document.activeElement;
        if (broadwaySecret(el)) return false;
        var typing = el && (el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && /^(text|search|url|email|tel|)$/.test((el.getAttribute('type') || '').toLowerCase())));
        if (typing) return (el.selectionEnd || 0) > (el.selectionStart || 0);
        var picked = getSelection();
        return !!(picked && !picked.isCollapsed && picked.rangeCount && picked.toString().trim());
      }
      window.addEventListener('contextmenu', function (e) {
        if (!e.isTrusted) return;
        var relay = window.webkit && webkit.messageHandlers && webkit.messageHandlers.broadwayTextActions;
        if (!relay) return;
        var ok = false;
        try { ok = offered(); } catch (error) { ok = false; }
        relay.postMessage({ offered: ok === true });
      }, true);
    })();
    """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let offered = message.frameInfo.isMainFrame && (message.body as? [String: Any])?["offered"] as? Bool == true
        MainActor.assumeIsolated { [weak self] in
            self?.tab?.built?.textOffered = offered
        }
    }
}

extension SettingsPageView {
    func textActionRow(_ id: String) {
        let prefs = prefs
        guard id == "ai.plan" else {
            row(id, control: toggle(id, get: { prefs.textActions }, set: { TextActions.set($0, prefs) }))
            return
        }
        let plans = Plans.shared
        browser.lookAtPlans()
        shape { [plans.looked ? "looked" : "", plans.agents.map(\.rawValue).joined(separator: ",")] }
        let agents = plans.agents
        let shown = agents.isEmpty ? Plan.cloud : agents
        let menu = popUp(id, titles: shown.map(TextActions.agentTitle), picked: {
            plans.agent(prefs).flatMap { shown.firstIndex(of: $0) } ?? 0
        }, set: { at in
            guard !agents.isEmpty, shown.indices.contains(at) else { return }
            prefs.aiPlan = shown[at]
        })
        row(id, control: menu)
    }
}
