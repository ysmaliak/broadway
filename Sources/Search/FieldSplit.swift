import Foundation

enum FieldSplit {
    static func loads(_ kind: Suggestion.Kind?, switches: Bool) -> Bool {
        guard !switches else { return false }
        guard let kind else { return true }
        switch kind {
        case .open, .visited, .bookmark, .known, .search, .suggested, .passage:
            return true
        case .placed(let item):
            return item.place == .history || item.place == .bookmarks
        case .action, .answer, .snippet:
            return false
        }
    }

    static func pairs(splitView: Bool, page: (blank: Bool, bench: Bool)?) -> Bool {
        guard splitView, let page else { return false }
        return !page.blank && !page.bench
    }

    static func splits(_ kind: Suggestion.Kind?, switches: Bool, splitView: Bool, page: (blank: Bool, bench: Bool)?) -> Bool {
        pairs(splitView: splitView, page: page) && loads(kind, switches: switches)
    }
}

extension Browser {
    var fieldPairs: Bool {
        FieldSplit.pairs(splitView: prefs.splitView, page: active.map { ($0.isBlank, $0.bench) })
    }

    func splitsFromField(_ kind: Suggestion.Kind?, switches: Bool = false) -> Bool {
        FieldSplit.splits(kind, switches: switches, splitView: prefs.splitView, page: active.map { ($0.isBlank, $0.bench) })
    }

    func openRowInSplit(_ offer: Suggestion) {
        openInSplit(offer.url)
        quitField()
    }

    func openPlacedInSplit(_ item: FieldPlaceItem) {
        openInSplit(item.url)
        quitField()
    }
}
