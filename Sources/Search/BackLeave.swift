import Foundation

struct BackLeaveCase: Equatable {
    var ownBack = false
    var stuck = false
    var blank = false
    var hasSource = true
    var sourceOpen = true
    var sourceAgent = false
    var pinned = false
    var split = false
    var agent = false
    var privateTab = false
    var privateSource = false
}

enum BackLeave {
    static func leaves(_ tab: BackLeaveCase) -> Bool {
        guard !tab.ownBack, !tab.stuck, !tab.blank, tab.hasSource, tab.sourceOpen else { return false }
        guard !tab.sourceAgent, !tab.pinned, !tab.split, !tab.agent else { return false }
        return !tab.privateTab || tab.privateSource
    }
}

@MainActor
extension Browser {
    func backSource(for tab: Tab) -> Tab? {
        let named = [tab.linkedFrom, tab.opener].compactMap { $0 }.filter { $0 != tab.id }
        let source = named.lazy.compactMap { id in self.tabs.first { $0.id == id } }.first
        let facts = BackLeaveCase(
            ownBack: tab.canGoBack,
            stuck: tab.isStuck,
            blank: tab.isBlank,
            hasSource: !named.isEmpty,
            sourceOpen: source != nil,
            sourceAgent: source.map { $0.agent || $0.bench } ?? false,
            pinned: tab.pin != nil,
            split: split(for: tab) != nil,
            agent: tab.agent || tab.bench,
            privateTab: !tab.store.isPersistent,
            privateSource: source.map { !$0.store.isPersistent } ?? false
        )
        return BackLeave.leaves(facts) ? source : nil
    }

    func backGoes(_ tab: Tab?) -> Bool {
        guard let tab else { return false }
        return tab.canGoBack || backSource(for: tab) != nil
    }

    @discardableResult
    func leaveBack(_ tab: Tab) -> Bool {
        guard tab.id == activeID, let source = backSource(for: tab) else { return false }
        guard !CallFloat.shared.asksBeforeClosing(tab, in: self) else { return true }
        tab.returnTo = source.id
        tab.returnWay = .front
        closeTab(tab)
        return true
    }

    func wireBack(_ tab: Tab) {
        tab.leave = { [weak self, weak tab] act in
            guard let self, let tab, tab.id == self.activeID else { return false }
            return act ? self.leaveBack(tab) : self.backSource(for: tab) != nil
        }
    }
}
