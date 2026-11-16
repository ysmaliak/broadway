import Foundation

@MainActor
final class FolderEmojis {
    static let shared = FolderEmojis()
    var standIn: (any AIGroupNamer)?
    private var requests: [UUID: UUID] = [:]

    var busy: Bool { !requests.isEmpty }

    private var engine: (any AIGroupNamer)? {
        if Store.testing, let standIn { return standIn }
        guard !Store.testing || CLIGuard.realAllowed, MacGroupEngine.available else { return nil }
        return MacGroupEngine()
    }

    func add(to id: UUID, in browser: Browser) {
        let token = UUID()
        requests[id] = token
        Task { [weak self, weak browser] in
            await Task.yield()
            guard let self, self.requests[id] == token else { return }
            defer { if self.requests[id] == token { self.requests[id] = nil } }
            guard let browser, browser.prefs.usesTabGroups, AIGroups.shared.emoji,
                  let group = browser.tabGroups.first(where: { $0.id == id }),
                  !group.ai, !group.live, !group.userIcon, group.icon == nil,
                  let engine = self.engine else { return }
            let space = browser.spaceID
            var tabs = browser.folderTabs(id).compactMap { AIGrouper.shown($0) }
            if tabs.isEmpty {
                tabs = [AIGroupTab(id: id, title: group.name, host: "", path: "")]
            }
            let ask = AIGroupNameAsk(tabs: tabs, current: nil, currentEmoji: nil, emoji: true)
            guard let said = try? await AIGrouper.within(AIGroups.shared.timeout, { try await engine.name(ask) }),
                  let mark = said.emoji.flatMap(AIGroupName.emoji(in:)),
                  self.requests[id] == token, browser.spaceID == space,
                  browser.prefs.usesTabGroups, AIGroups.shared.emoji,
                  let index = browser.tabGroups.firstIndex(where: { $0.id == id }),
                  browser.tabGroups[index].name == group.name,
                  !browser.tabGroups[index].userIcon, browser.tabGroups[index].icon == nil,
                  !browser.tabGroups[index].ai, !browser.tabGroups[index].live else { return }
            browser.tabGroups[index].icon = TabIcon(emoji: mark)
            browser.tabGroups[index].aiEmoji = mark
            browser.writeSession(now: true)
        }
    }
}
