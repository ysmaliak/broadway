import Foundation

struct LiveCloseFacts: Equatable {
    var made: Bool
    var showsRow: Bool
    var inFront: Bool
    var busy: Bool
    var typed: Bool?
}

@MainActor
enum LiveClose {
    enum Fate: Equatable { case close, keep, ask }

    static func fate(_ facts: LiveCloseFacts) -> Fate {
        guard facts.made, facts.showsRow, !facts.inFront, !facts.busy else { return .keep }
        guard let typed = facts.typed else { return .ask }
        return typed ? .keep : .close
    }

    static func shows(_ page: URL?, row key: String) -> Bool {
        guard let page else { return true }
        if LiveIdentity.of(page.absoluteString) == LiveIdentity.of(key) { return true }
        return LiveSeen.same(page, as: key)
    }

    private(set) static var asking: Set<UUID> = []
    private(set) static var answered: [UUID: Bool] = [:]

    static func take(_ tab: UUID) -> Bool? { answered.removeValue(forKey: tab) }

    static func ask(_ tab: Tab, then: @escaping @MainActor () -> Void) {
        guard asking.insert(tab.id).inserted else { return }
        let id = tab.id
        tab.unsaved { typed in
            MainActor.assumeIsolated {
                asking.remove(id)
                answered[id] = typed
                then()
                answered[id] = nil
            }
        }
    }
}

extension Browser {
    func liveFacts(_ tab: Tab, row key: String, typed: Bool?) -> LiveCloseFacts {
        let web = tab.built
        let busy = tab.noisy || web.map(StageView.onCall) == true
        return LiveCloseFacts(made: tab.liveKey != nil, showsRow: LiveClose.shows(tab.address, row: key),
                              inFront: visibleTabIDs.contains(tab.id) || floating == tab.id, busy: busy,
                              typed: tab.asleep || web == nil ? false : typed)
    }

    func liveFate(_ tab: Tab) -> LiveClose.Fate {
        guard let key = tab.liveKey else { return .keep }
        let fate = LiveClose.fate(liveFacts(tab, row: key, typed: LiveClose.take(tab.id)))
        guard fate == .ask else { return fate }
        LiveClose.ask(tab) { [weak self] in self?.syncLive() }
        return .ask
    }

    func closeLiveTab(_ tab: Tab) {
        tab.liveKey = nil
        tab.liveItem = nil
        tab.groupID = nil
        close(tab)
    }

    func freeLiveTab(_ tab: Tab) {
        tab.groupID = nil
        tab.liveKey = nil
        tab.liveItem = nil
        tab.leads = false
        tab.arrives = false
    }
}
