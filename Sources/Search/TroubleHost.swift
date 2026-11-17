import Foundation

enum TroubleHost {
    static func fieldShows(inFront: Bool, split: Bool, addressBar: Bool, folded: Bool) -> Bool {
        inFront && (split || (addressBar && !folded))
    }

    static func onPage(_ host: String?, fieldShows: Bool) -> String? {
        guard let host, !host.isEmpty, !fieldShows else { return nil }
        return Address.withoutWWW(host)
    }

    static func waits(now: Bool, loading: Bool, before: Bool) -> Bool {
        now || (loading && before)
    }
}

@MainActor
extension Browser {
    func troubleHost(for tab: Tab) -> String? {
        let shown = TroubleHost.fieldShows(inFront: tab.id == activeID, split: activeSplit?.contains(tab.id) == true,
                                           addressBar: prefs.addressBar, folded: folded)
        return TroubleHost.onPage(tab.address?.host() ?? tab.pending?.host(), fieldShows: shown)
    }
}

extension Tab {
    var popupTroubleHost: String? {
        let host = address?.host()
        return TroubleHost.onPage(host, fieldShows: host != nil && committed?.host() == host)
    }

    func troubleWaits(before: Bool) -> Bool {
        TroubleHost.waits(now: waitingForNetwork, loading: loading, before: before)
    }
}
